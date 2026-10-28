// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {RefereeFund} from "./RefereeFund.sol";

/// @notice The burn hook a locked token may offer (ERC20Burnable). Optional: see `_burnTranche`.
interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title KEPT Pledge Vault — promises the swarm enforces
/// @notice A team locks its tokens behind up to eight public milestones, each with a deadline and a
/// yes/no check the IMD swarm can answer. The beneficiary asks the swarm (each check costs IMD, paid
/// to the swarm's intake, up to three attempts per milestone). The swarm's panel signs an EIP-712
/// verdict; the vault checks the signatures, the panel and the quorum. Kept: the tranche unlocks to
/// the beneficiary and the Referee Fund refunds the check when it can. Not proven within three days
/// of the deadline: the tranche burns. Nothing can withdraw, pause or upgrade. Locked tokens move
/// only on a verdict or a missed deadline.
/// @dev Trust assumptions: the owner chooses the oracle (intake address, check price, signer panel,
/// quorum) and the Referee Fund. Oracle changes take effect after a seven-day notice so pledges can
/// see them coming; the first configuration, from unset, applies at once. The owner never touches
/// locked tokens or budgets. Verdicts are only as honest as the panel the owner configures.
contract PledgeVault is Ownable2Step, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ─────────────────────────────── constants ───────────────────────────────

    /// @notice Most milestones a pledge may carry.
    uint256 public constant MAX_MILESTONES = 8;
    /// @notice Check attempts a milestone may use (one check, two retries).
    uint8 public constant MAX_ATTEMPTS = 3;
    /// @notice Time after a deadline in which a kept verdict may still land. Afterwards the tranche burns.
    uint64 public constant GRACE = 3 days;
    /// @notice Notice period for oracle configuration changes.
    uint64 public constant NOTICE = 7 days;
    /// @notice Highest check price the owner may set: 0.5 IMD.
    uint256 public constant MAX_CHECK_PRICE = 0.5e18;
    /// @notice Most signers a panel may have.
    uint256 public constant MAX_PANEL = 16;
    /// @notice Longest pledge label, in bytes.
    uint256 public constant MAX_LABEL_LENGTH = 64;
    /// @notice Longest milestone check text, in bytes.
    uint256 public constant MAX_CHECK_LENGTH = 512;

    bytes32 public constant VERDICT_TYPEHASH =
        keccak256("Verdict(uint256 pledgeId,uint256 milestone,uint8 attempt,bool kept,uint256 expiry)");

    // ──────────────────────────────── types ─────────────────────────────────

    enum Status {
        Pending,
        Kept,
        Burned
    }

    struct MilestoneInput {
        /// @dev The yes/no check the swarm answers, as the team writes it.
        string check;
        /// @dev Unix time by which the milestone must be delivered.
        uint64 deadline;
        /// @dev Tranche released on a kept verdict, burned otherwise.
        uint256 amount;
    }

    struct Milestone {
        string check;
        uint64 deadline;
        uint256 amount;
        Status status;
        uint8 attempts;
        bool checkOpen;
        /// @dev IMD paid to the intake for the open check, refunded by the Referee Fund if kept.
        uint256 openCheckPrice;
    }

    struct Pledge {
        address creator;
        address beneficiary;
        IERC20 token;
        string label;
        uint64 createdAt;
        uint8 count;
        uint8 settled;
        /// @dev IMD available for checks. Unused budget returns to the creator once every milestone settles.
        uint256 budget;
        /// @dev IMD the Referee Fund has refunded into this budget.
        uint256 refunded;
    }

    struct OracleConfig {
        address intake;
        uint256 checkPrice;
        address[] signers;
        uint8 quorum;
    }

    // ─────────────────────────────── storage ────────────────────────────────

    /// @notice The paired currency checks are paid in (IMD on Ethereum).
    IERC20 public immutable imd;

    uint256 public pledgeCount;
    mapping(uint256 => Pledge) private _pledges;
    mapping(uint256 => Milestone[]) private _milestones;

    /// @notice Tokens of burned tranches the token itself could not burn, kept here forever.
    mapping(address => uint256) public stranded;

    /// @notice Where check payments go: the IMD swarm's intake. Unset until the owner configures it.
    address public intake;
    /// @notice IMD charged per check.
    uint256 public checkPrice;
    /// @notice Members of the current panel.
    mapping(address => bool) public isSigner;
    address[] private _signers;
    /// @notice Signatures a verdict needs.
    uint8 public quorum;

    OracleConfig private _pending;
    /// @notice When the pending oracle configuration may be applied (0: none pending).
    uint64 public pendingReadyAt;

    /// @notice Refunds kept checks. Set once by the owner after both contracts exist.
    RefereeFund public refereeFund;

    // ─────────────────────────────── events ─────────────────────────────────

    event PledgeCreated(
        uint256 indexed pledgeId, address indexed creator, address indexed beneficiary, address token, string label
    );
    event MilestoneAdded(
        uint256 indexed pledgeId, uint256 indexed milestone, uint64 deadline, uint256 amount, string check
    );
    event BudgetAdded(uint256 indexed pledgeId, address indexed from, uint256 amount);
    event BudgetReclaimed(uint256 indexed pledgeId, address indexed to, uint256 amount);
    event CheckRequested(
        uint256 indexed pledgeId, uint256 indexed milestone, uint8 attempt, uint256 price, string question
    );
    event VerdictAccepted(
        uint256 indexed pledgeId, uint256 indexed milestone, uint8 attempt, bool kept, uint256 signatures
    );
    event TrancheReleased(uint256 indexed pledgeId, uint256 indexed milestone, address indexed to, uint256 amount);
    event TrancheBurned(uint256 indexed pledgeId, uint256 indexed milestone, uint256 amount, bool burnedByToken);
    event CheckRefunded(uint256 indexed pledgeId, uint256 indexed milestone, uint256 requested, uint256 paid);
    event OracleConfigScheduled(address intake, uint256 checkPrice, address[] signers, uint8 quorum, uint64 readyAt);
    event OracleConfigCancelled();
    event OracleConfigApplied(address intake, uint256 checkPrice, address[] signers, uint8 quorum);
    event RefereeFundSet(address fund);

    // ─────────────────────────────── errors ─────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error TokenIsImd();
    error BadMilestoneCount(uint256 count);
    error LabelTooLong();
    error CheckTooLong();
    error EmptyCheck();
    error DeadlineNotAscending();
    error DeadlinePassed();
    error NotPlainToken(uint256 expected, uint256 received);
    error UnknownPledge();
    error UnknownMilestone();
    error NotBeneficiary();
    error NotPending();
    error OracleNotConfigured();
    error CheckAlreadyOpen();
    error NoCheckOpen();
    error AttemptMismatch(uint8 expected, uint8 given);
    error AttemptsExhausted();
    error InsufficientBudget(uint256 budget, uint256 price);
    error GraceOver();
    error GraceNotOver();
    error VerdictExpired();
    error NotEnoughSignatures(uint256 given, uint8 required);
    error UnknownSigner(address signer);
    error SignersNotAscending();
    error NotSettled();
    error PriceTooHigh();
    error BadPanel();
    error BadQuorum();
    error NothingPending();
    error NoticeNotOver(uint64 readyAt);
    error FundAlreadySet();
    error FundVaultMismatch();

    // ───────────────────────────── construction ─────────────────────────────

    /// @param owner_ The launch's owner: configures the oracle and the Referee Fund, nothing else.
    /// @param imd_ The IMD token checks are paid in.
    constructor(address owner_, address imd_) Ownable(owner_) EIP712("KEPT Pledge Vault", "1") {
        if (imd_ == address(0)) revert ZeroAddress();
        imd = IERC20(imd_);
    }

    // ─────────────────────────────── pledges ────────────────────────────────

    /// @notice Lock `token` behind milestones. Pulls every tranche and `budget` IMD from the caller.
    /// @dev The token must be a plain ERC-20: the amount received must equal the amount sent.
    function createPledge(
        address token,
        address beneficiary,
        string calldata label,
        MilestoneInput[] calldata milestones,
        uint256 budget
    ) external nonReentrant returns (uint256 pledgeId) {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (token == address(imd)) revert TokenIsImd();
        if (milestones.length == 0 || milestones.length > MAX_MILESTONES) revert BadMilestoneCount(milestones.length);
        if (bytes(label).length > MAX_LABEL_LENGTH) revert LabelTooLong();

        pledgeId = ++pledgeCount;
        Pledge storage p = _pledges[pledgeId];
        p.creator = msg.sender;
        p.beneficiary = beneficiary;
        p.token = IERC20(token);
        p.label = label;
        p.createdAt = uint64(block.timestamp);
        p.count = uint8(milestones.length);
        emit PledgeCreated(pledgeId, msg.sender, beneficiary, token, label);

        uint256 total;
        uint64 lastDeadline;
        Milestone[] storage ms = _milestones[pledgeId];
        for (uint256 i; i < milestones.length; ++i) {
            MilestoneInput calldata m = milestones[i];
            if (m.amount == 0) revert ZeroAmount();
            if (bytes(m.check).length == 0) revert EmptyCheck();
            if (bytes(m.check).length > MAX_CHECK_LENGTH) revert CheckTooLong();
            if (m.deadline <= block.timestamp) revert DeadlinePassed();
            if (m.deadline <= lastDeadline) revert DeadlineNotAscending();
            lastDeadline = m.deadline;
            total += m.amount;
            ms.push(
                Milestone({
                    check: m.check,
                    deadline: m.deadline,
                    amount: m.amount,
                    status: Status.Pending,
                    attempts: 0,
                    checkOpen: false,
                    openCheckPrice: 0
                })
            );
            emit MilestoneAdded(pledgeId, i, m.deadline, m.amount, m.check);
        }

        if (budget > 0) {
            p.budget = budget;
            emit BudgetAdded(pledgeId, msg.sender, budget);
            _pullExact(imd, budget);
        }
        _pullExact(IERC20(token), total);
    }

    /// @notice Add IMD to a pledge's check budget. Anyone may.
    function addBudget(uint256 pledgeId, uint256 amount) external nonReentrant {
        Pledge storage p = _pledge(pledgeId);
        if (amount == 0) revert ZeroAmount();
        p.budget += amount;
        emit BudgetAdded(pledgeId, msg.sender, amount);
        _pullExact(imd, amount);
    }

    /// @notice Return the unused budget to the creator once every milestone is settled. Anyone may call.
    function reclaimBudget(uint256 pledgeId) external nonReentrant {
        Pledge storage p = _pledge(pledgeId);
        if (p.settled != p.count) revert NotSettled();
        uint256 amount = p.budget;
        if (amount == 0) revert ZeroAmount();
        p.budget = 0;
        emit BudgetReclaimed(pledgeId, p.creator, amount);
        imd.safeTransfer(p.creator, amount);
    }

    // ──────────────────────────────── checks ────────────────────────────────

    /// @notice Ask the swarm whether a milestone is kept. Only the beneficiary; costs `checkPrice` IMD
    /// from the pledge's budget, paid to the intake. Allowed from creation until three days after the
    /// deadline, at most three times per milestone, one open check at a time.
    function requestCheck(uint256 pledgeId, uint256 milestone) external nonReentrant {
        Pledge storage p = _pledge(pledgeId);
        Milestone storage m = _milestone(pledgeId, milestone);
        if (msg.sender != p.beneficiary) revert NotBeneficiary();
        if (intake == address(0)) revert OracleNotConfigured();
        if (m.status != Status.Pending) revert NotPending();
        if (block.timestamp > m.deadline + GRACE) revert GraceOver();
        if (m.checkOpen) revert CheckAlreadyOpen();
        if (m.attempts >= MAX_ATTEMPTS) revert AttemptsExhausted();
        uint256 price = checkPrice;
        if (p.budget < price) revert InsufficientBudget(p.budget, price);

        p.budget -= price;
        m.attempts += 1;
        m.checkOpen = true;
        m.openCheckPrice = price;
        emit CheckRequested(pledgeId, milestone, m.attempts, price, question(pledgeId, milestone));
        if (price > 0) imd.safeTransfer(intake, price);
    }

    /// @notice Deliver the panel's verdict on the open check. Anyone may submit; the signatures decide.
    /// @param signatures Panel signatures over the EIP-712 `Verdict`, ordered by ascending signer address.
    function submitVerdict(
        uint256 pledgeId,
        uint256 milestone,
        uint8 attempt,
        bool kept,
        uint256 expiry,
        bytes[] calldata signatures
    ) external nonReentrant {
        Pledge storage p = _pledge(pledgeId);
        Milestone storage m = _milestone(pledgeId, milestone);
        if (m.status != Status.Pending) revert NotPending();
        if (!m.checkOpen) revert NoCheckOpen();
        if (attempt != m.attempts) revert AttemptMismatch(m.attempts, attempt);
        if (block.timestamp > expiry) revert VerdictExpired();
        if (block.timestamp > m.deadline + GRACE) revert GraceOver();
        _verifyPanel(verdictDigest(pledgeId, milestone, attempt, kept, expiry), signatures);

        m.checkOpen = false;
        uint256 paid = m.openCheckPrice;
        m.openCheckPrice = 0;
        emit VerdictAccepted(pledgeId, milestone, attempt, kept, signatures.length);
        if (!kept) return;

        m.status = Status.Kept;
        p.settled += 1;
        emit TrancheReleased(pledgeId, milestone, p.beneficiary, m.amount);
        p.token.safeTransfer(p.beneficiary, m.amount);

        RefereeFund fund = refereeFund;
        if (paid > 0 && address(fund) != address(0)) {
            uint256 refunded = fund.refund(paid);
            p.budget += refunded;
            p.refunded += refunded;
            emit CheckRefunded(pledgeId, milestone, paid, refunded);
        }
    }

    /// @notice Burn the tranche of a milestone not proven within three days of its deadline. Anyone may call.
    function settleMissed(uint256 pledgeId, uint256 milestone) external nonReentrant {
        Pledge storage p = _pledge(pledgeId);
        Milestone storage m = _milestone(pledgeId, milestone);
        if (m.status != Status.Pending) revert NotPending();
        if (block.timestamp <= m.deadline + GRACE) revert GraceNotOver();

        m.status = Status.Burned;
        m.checkOpen = false;
        m.openCheckPrice = 0;
        p.settled += 1;
        _burnTranche(pledgeId, milestone, p.token, m.amount);
    }

    // ───────────────────────────── oracle config ────────────────────────────

    /// @notice Schedule the oracle: intake address, check price (at most 0.5 IMD), panel and quorum.
    /// Applies at once while the vault is unconfigured, after seven days' notice afterwards.
    function scheduleOracleConfig(address intake_, uint256 checkPrice_, address[] calldata signers_, uint8 quorum_)
        external
        onlyOwner
    {
        if (intake_ == address(0)) revert ZeroAddress();
        if (checkPrice_ > MAX_CHECK_PRICE) revert PriceTooHigh();
        if (signers_.length == 0 || signers_.length > MAX_PANEL) revert BadPanel();
        for (uint256 i; i < signers_.length; ++i) {
            if (signers_[i] == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (signers_[j] == signers_[i]) revert BadPanel();
            }
        }
        if (quorum_ == 0 || quorum_ > signers_.length) revert BadQuorum();

        delete _pending;
        _pending.intake = intake_;
        _pending.checkPrice = checkPrice_;
        _pending.quorum = quorum_;
        for (uint256 i; i < signers_.length; ++i) {
            _pending.signers.push(signers_[i]);
        }
        uint64 readyAt = intake == address(0) ? uint64(block.timestamp) : uint64(block.timestamp) + NOTICE;
        pendingReadyAt = readyAt;
        emit OracleConfigScheduled(intake_, checkPrice_, signers_, quorum_, readyAt);
    }

    /// @notice Withdraw a scheduled configuration before it is applied.
    function cancelOracleConfig() external onlyOwner {
        if (pendingReadyAt == 0) revert NothingPending();
        delete _pending;
        pendingReadyAt = 0;
        emit OracleConfigCancelled();
    }

    /// @notice Apply the scheduled configuration once its notice has passed. Anyone may call.
    function applyOracleConfig() external {
        uint64 readyAt = pendingReadyAt;
        if (readyAt == 0) revert NothingPending();
        if (block.timestamp < readyAt) revert NoticeNotOver(readyAt);

        for (uint256 i; i < _signers.length; ++i) {
            isSigner[_signers[i]] = false;
        }
        delete _signers;
        address[] storage next = _pending.signers;
        for (uint256 i; i < next.length; ++i) {
            isSigner[next[i]] = true;
            _signers.push(next[i]);
        }
        intake = _pending.intake;
        checkPrice = _pending.checkPrice;
        quorum = _pending.quorum;
        emit OracleConfigApplied(intake, checkPrice, _signers, quorum);

        delete _pending;
        pendingReadyAt = 0;
    }

    /// @notice Point the vault at its Referee Fund. Once; the fund must name this vault.
    function setRefereeFund(address fund) external onlyOwner {
        if (fund == address(0)) revert ZeroAddress();
        if (address(refereeFund) != address(0)) revert FundAlreadySet();
        if (RefereeFund(fund).vault() != address(this)) revert FundVaultMismatch();
        refereeFund = RefereeFund(fund);
        emit RefereeFundSet(fund);
    }

    // ──────────────────────────────── views ─────────────────────────────────

    function getPledge(uint256 pledgeId) external view returns (Pledge memory) {
        return _pledge(pledgeId);
    }

    function getMilestone(uint256 pledgeId, uint256 milestone) external view returns (Milestone memory) {
        return _milestone(pledgeId, milestone);
    }

    function getMilestones(uint256 pledgeId) external view returns (Milestone[] memory) {
        _pledge(pledgeId);
        return _milestones[pledgeId];
    }

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function pendingOracleConfig() external view returns (OracleConfig memory) {
        return _pending;
    }

    /// @notice The exact question the swarm is asked. The vault writes it, so a team sees it before signing.
    function question(uint256 pledgeId, uint256 milestone) public view returns (string memory) {
        Milestone storage m = _milestone(pledgeId, milestone);
        return string.concat(
            "KEPT pledge #",
            pledgeId.toString(),
            ", milestone ",
            (milestone + 1).toString(),
            " of ",
            uint256(_pledges[pledgeId].count).toString(),
            ". Deadline (unix): ",
            uint256(m.deadline).toString(),
            ". Was this delivered by the deadline? ",
            m.check
        );
    }

    /// @notice The EIP-712 digest a panel member signs.
    function verdictDigest(uint256 pledgeId, uint256 milestone, uint8 attempt, bool kept, uint256 expiry)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(VERDICT_TYPEHASH, pledgeId, milestone, attempt, kept, expiry)));
    }

    // ─────────────────────────────── internals ──────────────────────────────

    function _pledge(uint256 pledgeId) private view returns (Pledge storage p) {
        p = _pledges[pledgeId];
        if (p.creator == address(0)) revert UnknownPledge();
    }

    function _milestone(uint256 pledgeId, uint256 milestone) private view returns (Milestone storage) {
        Milestone[] storage ms = _milestones[pledgeId];
        if (milestone >= ms.length) revert UnknownMilestone();
        return ms[milestone];
    }

    /// @dev Pull `amount` of `token` from the caller and insist that exactly that much arrived.
    function _pullExact(IERC20 token, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert NotPlainToken(amount, received);
    }

    /// @dev Signatures must come from distinct panel members in ascending address order and reach quorum.
    function _verifyPanel(bytes32 digest, bytes[] calldata signatures) private view {
        uint8 required = quorum;
        if (required == 0) revert OracleNotConfigured();
        if (signatures.length < required) revert NotEnoughSignatures(signatures.length, required);
        address last;
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= last) revert SignersNotAscending();
            if (!isSigner[signer]) revert UnknownSigner(signer);
            last = signer;
        }
    }

    /// @dev Burn through the token's own `burn` when it has one; otherwise the tranche stays here forever.
    function _burnTranche(uint256 pledgeId, uint256 milestone, IERC20 token, uint256 amount) private {
        bool burned = false;
        uint256 before = token.balanceOf(address(this));
        try IBurnable(address(token)).burn(amount) {
            burned = token.balanceOf(address(this)) == before - amount;
        } catch {}
        if (!burned) stranded[address(token)] += amount;
        emit TrancheBurned(pledgeId, milestone, amount, burned);
    }
}
