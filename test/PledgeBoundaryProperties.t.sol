// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeptToken} from "src/KeptToken.sol";
import {PledgeVault} from "src/PledgeVault.sol";
import {RefereeFund} from "src/RefereeFund.sol";
import {MockERC20, FeeOnTransferToken} from "./mocks/Mocks.sol";
import {PledgeSignatures} from "./helpers/PledgeSignatures.sol";

/// forge-config: default.fuzz.runs = 1000
contract PledgeBoundaryPropertiesTest is Test {
    uint256 constant PRICE = 0.5e18;
    KeptToken kept;
    MockERC20 imd;
    PledgeVault vault;
    RefereeFund fund;
    address creator;
    address beneficiary;
    address stranger;
    address intake;
    address signer;
    uint256 signerKey;

    function setUp() public {
        vm.warp(1_800_000_000);
        kept = new KeptToken();
        imd = new MockERC20("Test IMD", "IMD");
        vault = new PledgeVault(address(this), address(imd));
        fund = new RefereeFund(address(imd), address(vault));
        creator = makeAddr("boundary-creator");
        beneficiary = makeAddr("boundary-beneficiary");
        stranger = makeAddr("boundary-stranger");
        intake = makeAddr("boundary-intake");
        (signer, signerKey) = makeAddrAndKey("boundary-panel");
        vault.scheduleOracleConfig(intake, PRICE, _panel(), 1);
        vault.applyOracleConfig();
        vault.setRefereeFund(address(fund));
        kept.transfer(creator, 1_000e18);
        imd.mint(creator, 100e18);
        vm.startPrank(creator);
        kept.approve(address(vault), type(uint256).max);
        imd.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function test_creationRollsBackBudgetTransferAndIdWhenTokenPullFails() public {
        vm.startPrank(creator);
        kept.approve(address(vault), 0);
        imd.approve(address(vault), PRICE);
        PledgeVault.MilestoneInput[] memory ms = _milestones(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.createPledge(address(kept), beneficiary, "atomic creation", ms, PRICE);
        vm.stopPrank();
        assertEq(imd.balanceOf(creator), 100e18);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.allowance(creator, address(vault)), PRICE);
        assertEq(kept.balanceOf(address(vault)), 0);
        assertEq(vault.pledgeCount(), 0);
        vm.expectRevert(PledgeVault.UnknownPledge.selector);
        vault.getPledge(1);
        vm.prank(creator);
        kept.approve(address(vault), 1);
        assertEq(_create(1, 1, PRICE), 1, "failed creation must not consume an id");
    }

    function test_taxedTokenRejectionAlsoRestoresAlreadyPulledBudget() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        taxed.mint(creator, 100);
        PledgeVault.MilestoneInput[] memory ms = _milestones(1, 100);
        vm.startPrank(creator);
        taxed.approve(address(vault), 100);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.NotPlainToken.selector, 100, 99));
        vault.createPledge(address(taxed), beneficiary, "tax refusal", ms, PRICE);
        vm.stopPrank();
        assertEq(taxed.balanceOf(creator), 100);
        assertEq(taxed.allowance(creator, address(vault)), 100);
        assertEq(taxed.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(creator), 100e18);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(vault.pledgeCount(), 0);
    }

    function test_budgetFailureCannotCreateUnbackedCredit() public {
        uint256 id = _create(1, 1, PRICE);
        vm.prank(creator);
        imd.approve(address(vault), 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.addBudget(id, 1);
        assertEq(vault.getPledge(id).budget, PRICE);
        assertEq(imd.balanceOf(address(vault)), PRICE);
    }

    function test_otherPledgeCannotSubsidizeAnEmptyBudget() public {
        uint256 funded = _create(1, 1, 10e18);
        uint256 empty = _create(1, 1, 0);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.InsufficientBudget.selector, 0, PRICE));
        vault.requestCheck(empty, 0);
        assertEq(vault.getPledge(funded).budget, 10e18);
        assertEq(vault.getPledge(empty).budget, 0);
        assertEq(vault.getMilestone(empty, 0).attempts, 0);
        assertFalse(vault.getMilestone(empty, 0).checkOpen);
        assertEq(imd.balanceOf(intake), 0);
    }

    function test_lastGraceSecondAllowsCheckAndVerdictButNotMissedSettlement() public {
        uint256 id = _create(2, 1, PRICE);
        uint256 boundary = uint256(vault.getMilestone(id, 0).deadline) + 3 days;
        vm.warp(boundary);
        vm.expectRevert(PledgeVault.GraceNotOver.selector);
        vault.settleMissed(id, 0);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        _submit(id, 0, 1, true, boundary);
        assertEq(kept.balanceOf(beneficiary), 1);
        assertEq(uint8(vault.getMilestone(id, 0).status), uint8(PledgeVault.Status.Kept));
    }

    function test_oneSecondPastGraceRejectsEvenSignedOpenCheckAndBurnsExactlyOnce() public {
        uint256 id = _create(1, 1, PRICE);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = uint256(vault.getMilestone(id, 0).deadline) + 10 days;
        bytes[] memory sigs = _sign(address(vault), block.chainid, id, 0, 1, true, expiry);
        vm.warp(uint256(vault.getMilestone(id, 0).deadline) + 3 days + 1);
        vm.expectRevert(PledgeVault.GraceOver.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);
        vm.prank(beneficiary);
        vm.expectRevert(PledgeVault.GraceOver.selector);
        vault.requestCheck(id, 0);
        uint256 supply = kept.totalSupply();
        vm.prank(stranger);
        vault.settleMissed(id, 0);
        assertEq(kept.totalSupply(), supply - 1);
        assertEq(vault.getPledge(id).settled, 1);
        assertFalse(vault.getMilestone(id, 0).checkOpen);
        assertEq(vault.getMilestone(id, 0).openCheckPrice, 0);
        assertEq(vault.getPledge(id).refunded, 0);
        vm.expectRevert(PledgeVault.NotPending.selector);
        vault.settleMissed(id, 0);
        assertEq(kept.totalSupply(), supply - 1);
    }

    function test_refundUsesPricePaidBeforeOraclePriceChanges() public {
        _fund(PRICE);
        uint256 id = _create(1, 10, PRICE);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        vault.scheduleOracleConfig(intake, 0, _panel(), 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.applyOracleConfig();
        _submit(id, 0, 1, true, vm.getBlockTimestamp());
        assertEq(vault.checkPrice(), 0);
        assertEq(vault.getPledge(id).refunded, PRICE);
        assertEq(vault.getPledge(id).budget, PRICE);
        assertEq(fund.totalRefunded(), PRICE);
        assertEq(imd.balanceOf(intake), PRICE);
        vm.prank(stranger);
        vault.reclaimBudget(id);
        assertEq(imd.balanceOf(creator), 100e18);
        assertEq(imd.balanceOf(stranger), 0);
    }

    function test_freeChecksDoNotDrainFund() public {
        _fund(1e18);
        vault.scheduleOracleConfig(intake, 0, _panel(), 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.applyOracleConfig();
        uint256 id = _create(1, 1, 0);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        _submit(id, 0, 1, true, vm.getBlockTimestamp());
        assertEq(kept.balanceOf(beneficiary), 1);
        assertEq(vault.getPledge(id).refunded, 0);
        assertEq(fund.totalRefunded(), 0);
        assertEq(fund.balance(), 1e18);
        assertEq(imd.balanceOf(intake), 0);
    }

    function test_negativeVerdictCannotBeReplayedAgainstNextAttempt() public {
        uint256 id = _create(1, 1, 3 * PRICE);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = vm.getBlockTimestamp() + 1 days;
        _submit(id, 0, 1, false, expiry);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        bytes[] memory sigs = _sign(address(vault), block.chainid, id, 0, 1, false, expiry);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.AttemptMismatch.selector, 2, 1));
        vault.submitVerdict(id, 0, 1, false, expiry, sigs);
        assertTrue(vault.getMilestone(id, 0).checkOpen);
        assertEq(vault.getMilestone(id, 0).attempts, 2);
        assertEq(vault.getPledge(id).budget, PRICE);
        _submit(id, 0, 2, true, expiry);
        assertEq(kept.balanceOf(beneficiary), 1);
    }

    function test_verdictDomainBindsVaultAndChain() public {
        uint256 id = _create(1, 1, PRICE);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = vm.getBlockTimestamp() + 1 days;
        assertEq(
            vault.verdictDigest(id, 0, 1, true, expiry),
            PledgeSignatures.digest(address(vault), block.chainid, id, 0, 1, true, expiry)
        );
        PledgeVault other = new PledgeVault(address(this), address(imd));
        bytes[] memory sigs = _sign(address(other), block.chainid, id, 0, 1, true, expiry);
        vm.expectPartialRevert(PledgeVault.UnknownSigner.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);
        sigs = _sign(address(vault), block.chainid + 1, id, 0, 1, true, expiry);
        vm.expectPartialRevert(PledgeVault.UnknownSigner.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);
        assertEq(kept.balanceOf(address(vault)), 1);
        assertEq(kept.balanceOf(beneficiary), 0);
        assertTrue(vault.getMilestone(id, 0).checkOpen);
        _submit(id, 0, 1, true, expiry);
        assertEq(kept.balanceOf(beneficiary), 1);
    }

    function test_maximumMilestonesAndTextLengthsAreAccepted() public {
        PledgeVault.MilestoneInput[] memory ms = _milestones(8, 1);
        for (uint256 i; i < 8; ++i) {
            ms[i].check = string(new bytes(512));
        }
        string memory label = string(new bytes(64));
        vm.prank(creator);
        uint256 id = vault.createPledge(address(kept), beneficiary, label, ms, 0);
        assertEq(vault.getPledge(id).count, 8);
        assertEq(bytes(vault.getPledge(id).label).length, 64);
        assertEq(vault.getMilestones(id).length, 8);
        assertEq(bytes(vault.getMilestone(id, 7).check).length, 512);
        assertEq(kept.balanceOf(address(vault)), 8);
    }

    function testFuzz_multiMilestoneCreationAndPermissionlessReclaimConserveFunds(
        uint256 countSeed,
        uint256 amountSeed,
        uint256 budgetSeed
    ) public {
        uint256 count = bound(countSeed, 1, 8);
        uint256 amount = bound(amountSeed, 1, 1_000e18 / count);
        uint256 budget = bound(budgetSeed, 1, 100e18);
        uint256 id = _create(count, amount, budget);
        uint256 supply = kept.totalSupply();
        vm.warp(uint256(vault.getMilestone(id, count - 1).deadline) + 3 days + 1);
        // Settle in reverse order to check that settlement does not depend on milestone order.
        for (uint256 i = count; i > 0; --i) {
            vm.prank(stranger);
            vault.settleMissed(id, i - 1);
        }
        vm.prank(stranger);
        vault.reclaimBudget(id);
        assertEq(vault.getPledge(id).settled, count);
        assertEq(vault.getPledge(id).budget, 0);
        assertEq(imd.balanceOf(creator), 100e18);
        assertEq(imd.balanceOf(stranger), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(kept.balanceOf(address(vault)), 0);
        assertEq(kept.totalSupply(), supply - count * amount);
        vm.expectRevert(PledgeVault.ZeroAmount.selector);
        vault.reclaimBudget(id);
    }

    function testFuzz_repeatedKeptLifecyclesReturnOnlyDepositsAndPaidCheckRefunds(uint256 amountSeed, uint256 cycleSeed)
        public
    {
        uint256 amount = bound(amountSeed, 1, 1_000e18);
        uint256 cycles = bound(cycleSeed, 1, 8);
        _fund(cycles * PRICE);
        PledgeVault.MilestoneInput[] memory ms = _milestones(1, amount);
        for (uint256 i; i < cycles; ++i) {
            vm.prank(creator);
            uint256 id = vault.createPledge(address(kept), creator, "round trip", ms, PRICE);
            vm.prank(creator);
            vault.requestCheck(id, 0);
            _submit(id, 0, 1, true, vm.getBlockTimestamp());
            vm.prank(stranger);
            vault.reclaimBudget(id);
            assertEq(kept.balanceOf(creator), 1_000e18);
            assertEq(imd.balanceOf(creator), 100e18);
            assertEq(kept.balanceOf(address(vault)), 0);
            assertEq(imd.balanceOf(address(vault)), 0);
        }
        assertEq(fund.balance(), 0);
        assertEq(fund.totalRefunded(), cycles * PRICE);
        assertEq(imd.balanceOf(intake), cycles * PRICE);
    }

    function _create(uint256 count, uint256 amount, uint256 budget) private returns (uint256 id) {
        PledgeVault.MilestoneInput[] memory ms = _milestones(count, amount);
        vm.prank(creator);
        return vault.createPledge(address(kept), beneficiary, "boundary pledge", ms, budget);
    }

    function _milestones(uint256 count, uint256 amount) private view returns (PledgeVault.MilestoneInput[] memory ms) {
        ms = new PledgeVault.MilestoneInput[](count);
        for (uint256 i; i < count; ++i) {
            ms[i] = PledgeVault.MilestoneInput(
                "Deliver the milestone", uint64(vm.getBlockTimestamp() + (i + 1) * 30 days), amount
            );
        }
    }

    function _panel() private view returns (address[] memory panel) {
        panel = new address[](1);
        panel[0] = signer;
    }

    function _fund(uint256 amount) private {
        imd.mint(address(this), amount);
        imd.approve(address(fund), amount);
        fund.donate(amount);
    }

    function _submit(uint256 id, uint256 index, uint8 attempt, bool result, uint256 expiry) private {
        bytes[] memory sigs = _sign(address(vault), block.chainid, id, index, attempt, result, expiry);
        vault.submitVerdict(id, index, attempt, result, expiry, sigs);
    }

    function _sign(address target, uint256 chain, uint256 id, uint256 index, uint8 attempt, bool result, uint256 expiry)
        private
        view
        returns (bytes[] memory sigs)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, PledgeSignatures.digest(target, chain, id, index, attempt, result, expiry));
        sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
    }
}
