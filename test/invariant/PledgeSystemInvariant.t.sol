// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeptToken} from "src/KeptToken.sol";
import {PledgeVault} from "src/PledgeVault.sol";
import {RefereeFund} from "src/RefereeFund.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {PledgeSignatures} from "../helpers/PledgeSignatures.sol";

contract PledgeSystemHandler is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant PRICE = 0.5e18;
    uint256 constant MAX_PLEDGES = 12;

    struct ExpectedPledge {
        address creator;
        address beneficiary;
        address token;
        uint256 count;
        uint256 settled;
        uint256 budget;
        uint256 refunded;
    }

    struct ExpectedMilestone {
        uint256 amount;
        uint64 deadline;
        PledgeVault.Status status;
        uint8 attempts;
        bool open;
    }

    KeptToken public immutable kept;
    MockERC20 public immutable plain;
    MockERC20 public immutable imd;
    PledgeVault public immutable vault;
    RefereeFund public immutable fund;
    address public immutable intake;
    address[4] public actors;
    uint256[2] private keys;
    mapping(uint256 => ExpectedPledge) private pledges;
    mapping(uint256 => mapping(uint256 => ExpectedMilestone)) private milestones;
    mapping(address => mapping(address => uint256)) public expectedBalance;
    mapping(address => uint256) public tokenDeposited;
    mapping(address => uint256) public tokenReleased;
    mapping(address => uint256) public tokenDonated;
    uint256 public pledgeCount;
    uint256 public keptBurned;
    uint256 public plainStranded;
    uint256 public budgetsAdded;
    uint256 public budgetsReclaimed;
    uint256 public checksPaid;
    uint256 public keptCheckCost;
    uint256 public refunds;
    uint256 public fundDonated;
    uint256 public directFundDonations;
    uint256 public directVaultDonations;
    uint256 public requests;
    uint256 public keptVerdicts;
    uint256 public negativeVerdicts;
    uint256 public missedSettlements;
    uint256 public reclaims;
    uint256 public rejectedCalls;

    constructor() {
        kept = new KeptToken();
        plain = new MockERC20("Plain pledge token", "PLAIN");
        imd = new MockERC20("Test IMD", "IMD");
        vault = new PledgeVault(address(this), address(imd));
        fund = new RefereeFund(address(imd), address(vault));
        intake = makeAddr("invariant-intake");
        address[] memory panel = new address[](2);
        (panel[0], keys[0]) = makeAddrAndKey("invariant-panel-0");
        (panel[1], keys[1]) = makeAddrAndKey("invariant-panel-1");
        if (panel[1] < panel[0]) {
            (panel[0], panel[1]) = (panel[1], panel[0]);
            (keys[0], keys[1]) = (keys[1], keys[0]);
        }
        vault.scheduleOracleConfig(intake, PRICE, panel, 2);
        vault.applyOracleConfig();
        vault.setRefereeFund(address(fund));
        for (uint256 i; i < 4; ++i) {
            address actor = makeAddr(string.concat("pledge-actor-", vm.toString(i)));
            actors[i] = actor;
            kept.transfer(actor, SUPPLY / 4);
            plain.mint(actor, 250_000e18);
            imd.mint(actor, 100e18);
            expectedBalance[address(kept)][actor] = SUPPLY / 4;
            expectedBalance[address(plain)][actor] = 250_000e18;
            expectedBalance[address(imd)][actor] = 100e18;
            vm.startPrank(actor);
            kept.approve(address(vault), type(uint256).max);
            plain.approve(address(vault), type(uint256).max);
            imd.approve(address(vault), type(uint256).max);
            imd.approve(address(fund), type(uint256).max);
            vm.stopPrank();
        }
    }

    function create(
        uint256 creatorSeed,
        uint256 beneficiarySeed,
        bool usePlain,
        uint256 countSeed,
        uint256 rawAmount,
        uint256 rawBudget
    ) external {
        if (pledgeCount >= MAX_PLEDGES) return;
        address creator = actors[creatorSeed % 4];
        address beneficiary = actors[beneficiarySeed % 4];
        address asset = usePlain ? address(plain) : address(kept);
        uint256 count = bound(countSeed, 1, 8);
        uint256 maximum = expectedBalance[asset][creator] / count;
        if (maximum == 0) return;
        uint256 amount = bound(rawAmount, 1, maximum);
        uint256 budget = bound(rawBudget, 0, expectedBalance[address(imd)][creator]);
        PledgeVault.MilestoneInput[] memory inputs = new PledgeVault.MilestoneInput[](count);
        for (uint256 i; i < count; ++i) {
            inputs[i] = PledgeVault.MilestoneInput(
                "Deliver the milestone", uint64(vm.getBlockTimestamp() + (i + 1) * 5 days), amount
            );
        }
        vm.prank(creator);
        uint256 id = vault.createPledge(asset, beneficiary, "Invariant pledge", inputs, budget);
        ++pledgeCount;
        assertEq(id, pledgeCount);
        pledges[id] = ExpectedPledge(creator, beneficiary, asset, count, 0, budget, 0);
        for (uint256 i; i < count; ++i) {
            milestones[id][i] = ExpectedMilestone(amount, inputs[i].deadline, PledgeVault.Status.Pending, 0, false);
        }
        expectedBalance[asset][creator] -= amount * count;
        expectedBalance[address(imd)][creator] -= budget;
        tokenDeposited[asset] += amount * count;
        budgetsAdded += budget;
    }

    function addBudget(uint256 idSeed, uint256 actorSeed, uint256 raw) external {
        if (pledgeCount == 0) return;
        uint256 id = 1 + idSeed % pledgeCount;
        address actor = actors[actorSeed % 4];
        uint256 held = expectedBalance[address(imd)][actor];
        if (held == 0) return;
        uint256 amount = bound(raw, 1, held);
        vm.prank(actor);
        vault.addBudget(id, amount);
        pledges[id].budget += amount;
        expectedBalance[address(imd)][actor] -= amount;
        budgetsAdded += amount;
    }

    function donate(uint256 actorSeed, uint256 raw, bool direct) external {
        address actor = actors[actorSeed % 4];
        uint256 held = expectedBalance[address(imd)][actor];
        if (held == 0) return;
        uint256 amount = bound(raw, 1, held);
        vm.prank(actor);
        if (direct) {
            assertTrue(imd.transfer(address(fund), amount));
            directFundDonations += amount;
        } else {
            fund.donate(amount);
            fundDonated += amount;
        }
        expectedBalance[address(imd)][actor] -= amount;
    }

    function donateToVault(uint256 actorSeed, uint256 raw, uint256 assetSeed) external {
        address actor = actors[actorSeed % 4];
        address asset = assetSeed % 3 == 0 ? address(imd) : (assetSeed % 3 == 1 ? address(kept) : address(plain));
        uint256 amount = bound(raw, 0, expectedBalance[asset][actor]);
        vm.prank(actor);
        assertTrue(IERC20(asset).transfer(address(vault), amount));
        expectedBalance[asset][actor] -= amount;
        if (asset == address(imd)) directVaultDonations += amount;
        else tokenDonated[asset] += amount;
    }

    function request(uint256 seed) external {
        (uint256 id, uint256 index) = _find(seed, 0);
        if (id == 0) return;
        ExpectedPledge storage p = pledges[id];
        ExpectedMilestone storage m = milestones[id][index];
        vm.prank(p.beneficiary);
        vault.requestCheck(id, index);
        p.budget -= PRICE;
        ++m.attempts;
        m.open = true;
        checksPaid += PRICE;
        ++requests;
    }

    function verdict(uint256 seed, bool result) external {
        (uint256 id, uint256 index) = _find(seed, 1);
        if (id == 0) return;
        ExpectedPledge storage p = pledges[id];
        ExpectedMilestone storage m = milestones[id][index];
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes[] memory sigs = _sign(id, index, m.attempts, result, expiry);
        vault.submitVerdict(id, index, m.attempts, result, expiry, sigs);
        m.open = false;
        if (result) {
            uint256 available = fundDonated + directFundDonations - refunds;
            uint256 refund = available < PRICE ? available : PRICE;
            refunds += refund;
            p.refunded += refund;
            p.budget += refund;
            ++p.settled;
            m.status = PledgeVault.Status.Kept;
            tokenReleased[p.token] += m.amount;
            expectedBalance[p.token][p.beneficiary] += m.amount;
            keptCheckCost += PRICE;
            ++keptVerdicts;
        } else {
            ++negativeVerdicts;
        }
    }

    function advanceTime(uint256 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 1, 4 days));
    }

    function settle(uint256 seed) external {
        (uint256 id, uint256 index) = _find(seed, 2);
        if (id == 0) return;
        vault.settleMissed(id, index);
        ExpectedPledge storage p = pledges[id];
        ExpectedMilestone storage m = milestones[id][index];
        m.status = PledgeVault.Status.Burned;
        m.open = false;
        ++p.settled;
        if (p.token == address(kept)) keptBurned += m.amount;
        else plainStranded += m.amount;
        ++missedSettlements;
    }

    function reclaim(uint256 seed) external {
        if (pledgeCount == 0) return;
        for (uint256 i; i < pledgeCount; ++i) {
            uint256 id = 1 + (seed % pledgeCount + i) % pledgeCount;
            ExpectedPledge storage p = pledges[id];
            if (p.settled != p.count || p.budget == 0) continue;
            vault.reclaimBudget(id);
            expectedBalance[address(imd)][p.creator] += p.budget;
            budgetsReclaimed += p.budget;
            p.budget = 0;
            ++reclaims;
            return;
        }
    }

    function rejectUnauthorizedActions(uint256 seed) external {
        address outsider = actors[seed % 4];
        vm.prank(outsider);
        vm.expectRevert(RefereeFund.NotVault.selector);
        fund.refund(type(uint256).max);
        if (pledgeCount > 0) {
            uint256 id = 1 + seed % pledgeCount;
            ExpectedPledge storage p = pledges[id];
            if (outsider == p.beneficiary) outsider = actors[(seed % 4 + 1) % 4];
            vm.prank(outsider);
            vm.expectRevert(PledgeVault.NotBeneficiary.selector);
            vault.requestCheck(id, 0);
            if (p.settled != p.count) {
                vm.expectRevert(PledgeVault.NotSettled.selector);
                vault.reclaimBudget(id);
            }
        }
        ++rejectedCalls;
    }

    function rejectTerminalOrPrematureSettlement(uint256 seed) external {
        if (pledgeCount == 0) return;
        uint256 id = 1 + seed % pledgeCount;
        ExpectedPledge storage p = pledges[id];
        uint256 index = seed % p.count;
        ExpectedMilestone storage m = milestones[id][index];
        if (m.status != PledgeVault.Status.Pending) {
            vm.expectRevert(PledgeVault.NotPending.selector);
            vault.settleMissed(id, index);
            vm.prank(p.beneficiary);
            vm.expectRevert(PledgeVault.NotPending.selector);
            vault.requestCheck(id, index);
        } else if (vm.getBlockTimestamp() <= uint256(m.deadline) + 3 days) {
            vm.expectRevert(PledgeVault.GraceNotOver.selector);
            vault.settleMissed(id, index);
        } else {
            vm.prank(p.beneficiary);
            vm.expectRevert(PledgeVault.GraceOver.selector);
            vault.requestCheck(id, index);
        }
        ++rejectedCalls;
    }

    function assertTokenConservation() external view {
        uint256 keptHeld;
        uint256 plainHeld;
        for (uint256 id = 1; id <= pledgeCount; ++id) {
            ExpectedPledge storage p = pledges[id];
            for (uint256 i; i < p.count; ++i) {
                ExpectedMilestone storage m = milestones[id][i];
                if (m.status == PledgeVault.Status.Pending) {
                    if (p.token == address(kept)) keptHeld += m.amount;
                    else plainHeld += m.amount;
                }
            }
        }
        assertEq(tokenDeposited[address(kept)], keptHeld + tokenReleased[address(kept)] + keptBurned);
        assertEq(tokenDeposited[address(plain)], plainHeld + tokenReleased[address(plain)] + plainStranded);
        assertEq(kept.balanceOf(address(vault)), keptHeld + tokenDonated[address(kept)]);
        assertEq(plain.balanceOf(address(vault)), plainHeld + plainStranded + tokenDonated[address(plain)]);
        assertEq(vault.stranded(address(kept)), 0);
        assertEq(vault.stranded(address(plain)), plainStranded);
        assertEq(kept.totalSupply() + keptBurned, SUPPLY);
        assertEq(plain.totalSupply(), 1_000_000e18);
        uint256 sumKept = kept.balanceOf(address(vault));
        uint256 sumPlain = plain.balanceOf(address(vault));
        for (uint256 i; i < 4; ++i) {
            assertEq(kept.balanceOf(actors[i]), expectedBalance[address(kept)][actors[i]]);
            assertEq(plain.balanceOf(actors[i]), expectedBalance[address(plain)][actors[i]]);
            sumKept += kept.balanceOf(actors[i]);
            sumPlain += plain.balanceOf(actors[i]);
        }
        assertEq(sumKept, kept.totalSupply());
        assertEq(sumPlain, plain.totalSupply());
    }

    function assertBudgetAndFundConservation() external view {
        uint256 budgets;
        uint256 pledgeRefunds;
        for (uint256 id = 1; id <= pledgeCount; ++id) {
            PledgeVault.Pledge memory actual = vault.getPledge(id);
            assertEq(actual.budget, pledges[id].budget);
            assertEq(actual.refunded, pledges[id].refunded);
            budgets += actual.budget;
            pledgeRefunds += actual.refunded;
        }
        assertEq(budgets + checksPaid + budgetsReclaimed, budgetsAdded + refunds);
        assertEq(imd.balanceOf(address(vault)), budgets + directVaultDonations);
        assertEq(fund.balance() + refunds, fundDonated + directFundDonations);
        assertEq(fund.totalDonated(), fundDonated);
        assertEq(fund.totalRefunded(), refunds);
        assertEq(pledgeRefunds, refunds);
        assertLe(refunds, keptCheckCost, "only successful, paid checks may be refunded");
        assertEq(imd.balanceOf(intake), checksPaid);
        uint256 sum = imd.balanceOf(address(vault)) + fund.balance() + imd.balanceOf(intake);
        for (uint256 i; i < 4; ++i) {
            assertEq(imd.balanceOf(actors[i]), expectedBalance[address(imd)][actors[i]]);
            sum += imd.balanceOf(actors[i]);
        }
        assertEq(sum, 400e18);
        assertEq(imd.totalSupply(), 400e18);
    }

    function assertMilestoneState() external view {
        assertEq(vault.pledgeCount(), pledgeCount);
        for (uint256 id = 1; id <= pledgeCount; ++id) {
            ExpectedPledge storage p = pledges[id];
            PledgeVault.Pledge memory actual = vault.getPledge(id);
            assertEq(actual.creator, p.creator);
            assertEq(actual.beneficiary, p.beneficiary);
            assertEq(address(actual.token), p.token);
            assertEq(actual.count, p.count);
            assertEq(actual.settled, p.settled);
            PledgeVault.Milestone[] memory ms = vault.getMilestones(id);
            assertEq(ms.length, p.count);
            uint256 terminal;
            for (uint256 i; i < p.count; ++i) {
                ExpectedMilestone storage m = milestones[id][i];
                assertEq(ms[i].amount, m.amount);
                assertEq(ms[i].deadline, m.deadline);
                assertEq(uint8(ms[i].status), uint8(m.status));
                assertEq(ms[i].attempts, m.attempts);
                assertLe(ms[i].attempts, 3);
                assertEq(ms[i].checkOpen, m.open);
                assertEq(ms[i].openCheckPrice, m.open ? PRICE : 0);
                if (ms[i].status != PledgeVault.Status.Pending) {
                    ++terminal;
                    assertFalse(ms[i].checkOpen);
                }
            }
            assertEq(terminal, actual.settled);
        }
    }

    /// @dev Scan from a fuzzed starting point so verdict/settlement handlers reach eligible work.
    function _find(uint256 seed, uint256 mode) private view returns (uint256 id, uint256 index) {
        if (pledgeCount == 0) return (0, 0);
        for (uint256 i; i < pledgeCount; ++i) {
            id = 1 + (seed % pledgeCount + i) % pledgeCount;
            ExpectedPledge storage p = pledges[id];
            for (uint256 j; j < p.count; ++j) {
                index = (seed % p.count + j) % p.count;
                ExpectedMilestone storage m = milestones[id][index];
                if (m.status != PledgeVault.Status.Pending) continue;
                bool expired = vm.getBlockTimestamp() > uint256(m.deadline) + 3 days;
                if (mode == 0 && !expired && !m.open && m.attempts < 3 && p.budget >= PRICE) return (id, index);
                if (mode == 1 && !expired && m.open) return (id, index);
                if (mode == 2 && expired) return (id, index);
            }
        }
        return (0, 0);
    }

    function _sign(uint256 id, uint256 index, uint8 attempt, bool result, uint256 expiry)
        private
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = PledgeSignatures.digest(address(vault), block.chainid, id, index, attempt, result, expiry);
        sigs = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PledgeSystemInvariantTest is Test {
    PledgeSystemHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new PledgeSystemHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.addBudget.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.donateToVault.selector;
        selectors[4] = handler.request.selector;
        selectors[5] = handler.verdict.selector;
        selectors[6] = handler.advanceTime.selector;
        selectors[7] = handler.settle.selector;
        selectors[8] = handler.reclaim.selector;
        selectors[9] = handler.rejectUnauthorizedActions.selector;
        selectors[10] = handler.rejectTerminalOrPrematureSettlement.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_lockedTokensAreReleasedBurnedOrStillBacked() public view {
        handler.assertTokenConservation();
    }

    function invariant_checkBudgetsAndFundRefundsAreFullyBacked() public view {
        handler.assertBudgetAndFundConservation();
    }

    function invariant_milestonesFollowTheStateMachine() public view {
        handler.assertMilestoneState();
    }

    /// @dev Exercise every economically significant branch even if a random sequence is sparse.
    function test_handlerReachesRefundRetryBurnStrandingAndReclaim() public {
        handler.donate(3, 1e18, false);
        handler.donate(3, 1, true);
        handler.create(0, 1, false, 2, 10, 2e18);
        handler.create(1, 2, true, 1, 10, 1e18);
        handler.donateToVault(2, 1, 0);
        handler.donateToVault(2, 1, 1);
        handler.donateToVault(2, 1, 2);
        handler.request(0);
        handler.verdict(0, false);
        handler.request(0);
        handler.verdict(0, true);
        handler.rejectTerminalOrPrematureSettlement(0);
        handler.rejectUnauthorizedActions(0);
        handler.advanceTime(4 days);
        handler.advanceTime(4 days);
        handler.advanceTime(4 days);
        handler.advanceTime(4 days);
        handler.settle(0);
        handler.settle(1);
        handler.reclaim(0);
        handler.reclaim(1);
        invariant_lockedTokensAreReleasedBurnedOrStillBacked();
        invariant_checkBudgetsAndFundRefundsAreFullyBacked();
        invariant_milestonesFollowTheStateMachine();
        assertEq(handler.keptVerdicts(), 1);
        assertEq(handler.negativeVerdicts(), 1);
        assertEq(handler.missedSettlements(), 2);
        assertEq(handler.reclaims(), 2);
        assertEq(handler.keptBurned(), 10);
        assertEq(handler.plainStranded(), 10);
        assertEq(handler.refunds(), 0.5e18);
    }
}
