// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeptToken} from "src/KeptToken.sol";
import {PledgeVault} from "src/PledgeVault.sol";
import {RefereeFund} from "src/RefereeFund.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {PledgeSignatures} from "./helpers/PledgeSignatures.sol";

/// @notice Burns `bps` / 10_000 of what it is asked to burn, rounding down.
contract FractionBurnToken is ERC20 {
    uint256 public immutable bps;

    constructor(uint256 bps_) ERC20("Fraction", "FRAC") {
        bps = bps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount * bps / 10_000);
    }
}

/// @notice Names the right vault and IMD, but pays the vault twice what it is asked for.
contract OverpayingFund {
    IERC20 public immutable imd;
    address public immutable vault;

    constructor(IERC20 imd_, address vault_) {
        imd = imd_;
        vault = vault_;
    }

    function refund(uint256 amount) external returns (uint256) {
        imd.transfer(vault, 2 * amount);
        return 2 * amount;
    }
}

/// @notice Names the right vault and IMD, and tries to re-enter the vault from `refund`.
contract ReenteringFund {
    IERC20 public immutable imd;
    address public immutable vault;
    uint256 public target;

    constructor(IERC20 imd_, address vault_) {
        imd = imd_;
        vault = vault_;
    }

    function setTarget(uint256 pledgeId) external {
        target = pledgeId;
        imd.approve(vault, type(uint256).max);
    }

    function refund(uint256 amount) external returns (uint256) {
        imd.transfer(vault, amount);
        PledgeVault(vault).addBudget(target, 1);
        return amount;
    }
}

/// @notice Regression and edge tests for the refund-crediting, partial-burn and deadline-range fixes.
/// forge-config: default.fuzz.runs = 1000
contract PledgeRefundAndBurnRegressionsTest is Test {
    uint256 constant PRICE = 0.5e18;
    uint64 constant T0 = 1_800_000_000;
    KeptToken kept;
    MockERC20 imd;
    PledgeVault vault;
    address creator;
    address beneficiary;
    address intake;
    address signer;
    uint256 signerKey;

    function setUp() public {
        vm.warp(T0);
        kept = new KeptToken();
        imd = new MockERC20("Test IMD", "IMD");
        vault = new PledgeVault(address(this), address(imd));
        creator = makeAddr("regression-creator");
        beneficiary = makeAddr("regression-beneficiary");
        intake = makeAddr("regression-intake");
        (signer, signerKey) = makeAddrAndKey("regression-panel");
        address[] memory panel = new address[](1);
        panel[0] = signer;
        vault.scheduleOracleConfig(intake, PRICE, panel, 1);
        vault.applyOracleConfig();
        kept.transfer(creator, 1_000e18);
        imd.mint(creator, 100e18);
        vm.startPrank(creator);
        kept.approve(address(vault), type(uint256).max);
        imd.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ───────────────────────────── refund crediting ─────────────────────────────

    function testFuzz_realFundCreditsExactlyWhatItCouldPay(uint256 held) public {
        held = bound(held, 0, 2 * PRICE);
        RefereeFund fund = new RefereeFund(address(imd), address(vault));
        vault.setRefereeFund(address(fund));
        if (held > 0) {
            imd.mint(address(this), held);
            imd.approve(address(fund), held);
            fund.donate(held);
        }
        uint256 id = _create(address(kept), 1, 7, 2 * PRICE);
        _keep(id, 0, 1);

        uint256 credit = held < PRICE ? held : PRICE;
        assertEq(vault.getPledge(id).refunded, credit);
        assertEq(vault.getPledge(id).budget, PRICE + credit);
        assertEq(fund.totalRefunded(), credit);
        assertEq(imd.balanceOf(address(fund)), held - credit);
        assertEq(imd.balanceOf(address(vault)), PRICE + credit, "vault IMD must back the budget exactly");
        assertEq(kept.balanceOf(beneficiary), 7);

        vault.reclaimBudget(id);
        assertEq(imd.balanceOf(creator), 100e18 - PRICE + credit);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_overpayingFundCreditsOnlyThePricePaid() public {
        OverpayingFund fund = new OverpayingFund(imd, address(vault));
        imd.mint(address(fund), 10e18);
        vault.setRefereeFund(address(fund));
        uint256 id = _create(address(kept), 1, 7, PRICE);
        _keep(id, 0, 1);

        assertEq(vault.getPledge(id).refunded, PRICE, "credit is capped at the price paid");
        assertEq(vault.getPledge(id).budget, PRICE);
        assertEq(imd.balanceOf(address(vault)), 2 * PRICE, "surplus stays in the vault, unowed");
        vault.reclaimBudget(id);
        assertEq(imd.balanceOf(creator), 100e18, "the creator recovers only what it deposited");
        assertEq(imd.balanceOf(address(vault)), PRICE);
    }

    function test_fundThatReentersCreditsNothingButReleaseStands() public {
        ReenteringFund fund = new ReenteringFund(imd, address(vault));
        imd.mint(address(fund), 10e18);
        vault.setRefereeFund(address(fund));
        uint256 id = _create(address(kept), 1, 7, PRICE);
        fund.setTarget(id);
        _keep(id, 0, 1);

        assertEq(uint8(vault.getMilestone(id, 0).status), uint8(PledgeVault.Status.Kept));
        assertEq(kept.balanceOf(beneficiary), 7);
        assertEq(vault.getPledge(id).refunded, 0, "the reentrant refund rolled back and credits nothing");
        assertEq(vault.getPledge(id).budget, 0);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(address(fund)), 10e18);
    }

    function test_setRefereeFundRejectsAccountWithoutFundInterface() public {
        vm.expectRevert();
        vault.setRefereeFund(makeAddr("not-a-fund"));
        vm.expectRevert();
        vault.setRefereeFund(address(imd));
        assertEq(address(vault.refereeFund()), address(0));
    }

    function test_setRefereeFundIsOwnerOnlyEvenForAValidFund() public {
        RefereeFund fund = new RefereeFund(address(imd), address(vault));
        vm.prank(creator);
        vm.expectRevert();
        vault.setRefereeFund(address(fund));
        assertEq(address(vault.refereeFund()), address(0));
    }

    // ─────────────────────────────── partial burns ──────────────────────────────

    function testFuzz_partialBurnStrandsExactlyTheUnburnedRemainder(uint256 bps, uint256 a, uint256 b) public {
        bps = bound(bps, 0, 10_000);
        a = bound(a, 1, 1e30);
        b = bound(b, 1, 1e30);
        FractionBurnToken token = new FractionBurnToken(bps);
        token.mint(creator, a + b);
        vm.prank(creator);
        token.approve(address(vault), a + b);
        uint256 missed = _create(address(token), 1, a, 0);
        uint256 later = _createAt(address(token), b, 0, T0 + 60 days);

        vm.warp(T0 + 30 days + 3 days + 1);
        vault.settleMissed(missed, 0);
        uint256 burned = a * bps / 10_000;
        assertEq(token.totalSupply(), a + b - burned);
        assertEq(vault.stranded(address(token)), a - burned);
        assertEq(token.balanceOf(address(vault)), b + vault.stranded(address(token)));

        // The burn of one pledge must never eat into another pledge of the same token.
        _keep(later, 0, 1);
        assertEq(token.balanceOf(beneficiary), b);
        assertEq(token.balanceOf(address(vault)), vault.stranded(address(token)));
    }

    // ────────────────────────────── deadline range ──────────────────────────────

    function testFuzz_everyAcceptedDeadlineCanStillSettle(uint64 deadline) public {
        uint64 limit = type(uint64).max - vault.GRACE();
        deadline = uint64(bound(deadline, limit - 1_000, type(uint64).max));
        PledgeVault.MilestoneInput[] memory ms = new PledgeVault.MilestoneInput[](1);
        ms[0] = PledgeVault.MilestoneInput("Deliver the milestone", deadline, 1);
        vm.prank(creator);
        if (deadline >= limit) {
            vm.expectRevert(PledgeVault.DeadlineTooFar.selector);
            vault.createPledge(address(kept), beneficiary, "far", ms, 0);
            assertEq(vault.pledgeCount(), 0);
            return;
        }
        uint256 id = vault.createPledge(address(kept), beneficiary, "far", ms, 0);
        vm.warp(uint256(deadline) + vault.GRACE());
        vm.expectRevert(PledgeVault.GraceNotOver.selector);
        vault.settleMissed(id, 0);
        vm.warp(uint256(deadline) + vault.GRACE() + 1);
        uint256 supply = kept.totalSupply();
        vault.settleMissed(id, 0);
        assertEq(uint8(vault.getMilestone(id, 0).status), uint8(PledgeVault.Status.Burned));
        assertEq(kept.totalSupply(), supply - 1);
    }

    function test_laterTooFarMilestoneRollsBackWholePledge() public {
        PledgeVault.MilestoneInput[] memory ms = new PledgeVault.MilestoneInput[](2);
        ms[0] = PledgeVault.MilestoneInput("Deliver the milestone", T0 + 30 days, 1);
        ms[1] = PledgeVault.MilestoneInput("Deliver the milestone", type(uint64).max - vault.GRACE(), 1);
        vm.prank(creator);
        vm.expectRevert(PledgeVault.DeadlineTooFar.selector);
        vault.createPledge(address(kept), beneficiary, "far", ms, PRICE);
        assertEq(vault.pledgeCount(), 0);
        assertEq(kept.balanceOf(creator), 1_000e18);
        assertEq(imd.balanceOf(creator), 100e18);
    }

    // ────────────────────────────────── helpers ─────────────────────────────────

    function _create(address token, uint256 count, uint256 amount, uint256 budget) private returns (uint256) {
        PledgeVault.MilestoneInput[] memory ms = new PledgeVault.MilestoneInput[](count);
        for (uint256 i; i < count; ++i) {
            ms[i] = PledgeVault.MilestoneInput("Deliver the milestone", uint64(T0 + (i + 1) * 30 days), amount);
        }
        vm.prank(creator);
        return vault.createPledge(token, beneficiary, "regression pledge", ms, budget);
    }

    function _createAt(address token, uint256 amount, uint256 budget, uint64 deadline) private returns (uint256) {
        PledgeVault.MilestoneInput[] memory ms = new PledgeVault.MilestoneInput[](1);
        ms[0] = PledgeVault.MilestoneInput("Deliver the milestone", deadline, amount);
        vm.prank(creator);
        return vault.createPledge(token, beneficiary, "regression pledge", ms, budget);
    }

    function _keep(uint256 id, uint256 index, uint8 attempt) private {
        if (vault.getPledge(id).budget >= vault.checkPrice()) {
            vm.prank(beneficiary);
            vault.requestCheck(id, index);
        } else {
            imd.mint(address(this), PRICE);
            imd.approve(address(vault), PRICE);
            vault.addBudget(id, PRICE);
            vm.prank(beneficiary);
            vault.requestCheck(id, index);
        }
        uint256 expiry = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, PledgeSignatures.digest(address(vault), block.chainid, id, index, attempt, true, expiry));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
        vault.submitVerdict(id, index, attempt, true, expiry, sigs);
    }
}
