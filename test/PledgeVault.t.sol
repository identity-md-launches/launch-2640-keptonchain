// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {KeptToken} from "../src/KeptToken.sol";
import {PledgeVault} from "../src/PledgeVault.sol";
import {RefereeFund} from "../src/RefereeFund.sol";
import {MockERC20, FeeOnTransferToken, FakeBurnToken} from "./mocks/Mocks.sol";

contract PledgeVaultTest is Test {
    uint256 constant PRICE = 0.5e18;
    uint256 constant T0 = 1_800_000_000;

    KeptToken kept;
    MockERC20 imd;
    PledgeVault vault;
    RefereeFund fund;

    address owner = makeAddr("owner");
    address team = makeAddr("team");
    address beneficiary = makeAddr("beneficiary");
    address intake = makeAddr("intake");
    address stranger = makeAddr("stranger");

    uint256[3] keys;
    address[] panel;

    function setUp() public {
        vm.warp(T0);
        kept = new KeptToken();
        imd = new MockERC20("IMD", "IMD");
        vault = new PledgeVault(owner, address(imd));
        fund = new RefereeFund(address(imd), address(vault));

        // Three panel members, sorted by address so tests can sign in order.
        address[] memory raw = new address[](3);
        uint256[] memory rawKeys = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            (raw[i], rawKeys[i]) = makeAddrAndKey(string.concat("panel-", vm.toString(i)));
        }
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (raw[j] < raw[i]) {
                    (raw[i], raw[j]) = (raw[j], raw[i]);
                    (rawKeys[i], rawKeys[j]) = (rawKeys[j], rawKeys[i]);
                }
            }
        }
        for (uint256 i; i < 3; ++i) {
            panel.push(raw[i]);
            keys[i] = rawKeys[i];
        }

        kept.transfer(team, 10_000_000e18);
        imd.mint(team, 100e18);
        imd.mint(stranger, 100e18);
        vm.startPrank(team);
        kept.approve(address(vault), type(uint256).max);
        imd.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(stranger);
        imd.approve(address(vault), type(uint256).max);
    }

    // ────────────────────────────── helpers ──────────────────────────────

    function _configure() internal {
        vm.prank(owner);
        vault.scheduleOracleConfig(intake, PRICE, panel, 2);
        vault.applyOracleConfig();
    }

    function _attachFund(uint256 seed) internal {
        vm.prank(owner);
        vault.setRefereeFund(address(fund));
        if (seed > 0) {
            imd.mint(address(this), seed);
            imd.approve(address(fund), seed);
            fund.donate(seed);
        }
    }

    function _milestones(uint256 n, uint256 amount) internal view returns (PledgeVault.MilestoneInput[] memory ms) {
        ms = new PledgeVault.MilestoneInput[](n);
        for (uint256 i; i < n; ++i) {
            ms[i] = PledgeVault.MilestoneInput({
                check: string.concat("Milestone ", vm.toString(i + 1), " shipped"),
                deadline: uint64(block.timestamp + (i + 1) * 30 days),
                amount: amount
            });
        }
    }

    function _create(uint256 n, uint256 amount, uint256 budget) internal returns (uint256 id) {
        vm.prank(team);
        id = vault.createPledge(address(kept), beneficiary, "KEPT roadmap", _milestones(n, amount), budget);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _verdict(uint256 id, uint256 m, uint8 attempt, bool kept_, uint256 expiry, uint256 count)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = vault.verdictDigest(id, m, attempt, kept_, expiry);
        sigs = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            sigs[i] = _sign(keys[i], digest);
        }
    }

    // ───────────────────────────── creation ──────────────────────────────

    function test_createPledgeLocksTokensAndBudget() public {
        uint256 id = _create(3, 1_000e18, 2e18);
        assertEq(id, 1);
        assertEq(vault.pledgeCount(), 1);
        assertEq(kept.balanceOf(address(vault)), 3_000e18);
        assertEq(imd.balanceOf(address(vault)), 2e18);

        PledgeVault.Pledge memory p = vault.getPledge(id);
        assertEq(p.creator, team);
        assertEq(p.beneficiary, beneficiary);
        assertEq(address(p.token), address(kept));
        assertEq(p.label, "KEPT roadmap");
        assertEq(p.count, 3);
        assertEq(p.settled, 0);
        assertEq(p.budget, 2e18);

        PledgeVault.Milestone[] memory ms = vault.getMilestones(id);
        assertEq(ms.length, 3);
        assertEq(ms[1].deadline, T0 + 60 days);
        assertEq(ms[1].amount, 1_000e18);
        assertEq(uint8(ms[1].status), uint8(PledgeVault.Status.Pending));
    }

    function test_createPledgeWorksBeforeOracleIsConfigured() public {
        uint256 id = _create(1, 1e18, 0);
        assertEq(vault.getPledge(id).budget, 0);
        assertEq(vault.intake(), address(0));
    }

    function test_createPledgeValidation() public {
        PledgeVault.MilestoneInput[] memory ms = _milestones(1, 1e18);

        vm.startPrank(team);
        vm.expectRevert(PledgeVault.ZeroAddress.selector);
        vault.createPledge(address(0), beneficiary, "x", ms, 0);
        vm.expectRevert(PledgeVault.ZeroAddress.selector);
        vault.createPledge(address(kept), address(0), "x", ms, 0);
        vm.expectRevert(PledgeVault.TokenIsImd.selector);
        vault.createPledge(address(imd), beneficiary, "x", ms, 0);

        vm.expectRevert(abi.encodeWithSelector(PledgeVault.BadMilestoneCount.selector, 0));
        vault.createPledge(address(kept), beneficiary, "x", new PledgeVault.MilestoneInput[](0), 0);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.BadMilestoneCount.selector, 9));
        vault.createPledge(address(kept), beneficiary, "x", _milestones(9, 1e18), 0);

        string memory longLabel = new string(65);
        vm.expectRevert(PledgeVault.LabelTooLong.selector);
        vault.createPledge(address(kept), beneficiary, longLabel, ms, 0);

        ms[0].amount = 0;
        vm.expectRevert(PledgeVault.ZeroAmount.selector);
        vault.createPledge(address(kept), beneficiary, "x", ms, 0);
        ms[0].amount = 1e18;

        ms[0].check = "";
        vm.expectRevert(PledgeVault.EmptyCheck.selector);
        vault.createPledge(address(kept), beneficiary, "x", ms, 0);
        ms[0].check = new string(513);
        vm.expectRevert(PledgeVault.CheckTooLong.selector);
        vault.createPledge(address(kept), beneficiary, "x", ms, 0);
        ms[0].check = "ok";

        ms[0].deadline = uint64(block.timestamp);
        vm.expectRevert(PledgeVault.DeadlinePassed.selector);
        vault.createPledge(address(kept), beneficiary, "x", ms, 0);

        PledgeVault.MilestoneInput[] memory two = _milestones(2, 1e18);
        two[1].deadline = two[0].deadline;
        vm.expectRevert(PledgeVault.DeadlineNotAscending.selector);
        vault.createPledge(address(kept), beneficiary, "x", two, 0);
        vm.stopPrank();
    }

    function test_createPledgeRefusesFeeOnTransferToken() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        taxed.mint(team, 1_000e18);
        vm.startPrank(team);
        taxed.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.NotPlainToken.selector, 100e18, 99e18));
        vault.createPledge(address(taxed), beneficiary, "x", _milestones(1, 100e18), 0);
        vm.stopPrank();
    }

    function test_createPledgeRevertsWithoutAllowance() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.createPledge(address(kept), beneficiary, "x", _milestones(1, 1e18), 0);
    }

    function test_addBudgetByAnyone() public {
        uint256 id = _create(1, 1e18, 0);
        vm.prank(stranger);
        vault.addBudget(id, 3e18);
        assertEq(vault.getPledge(id).budget, 3e18);
        assertEq(imd.balanceOf(address(vault)), 3e18);

        vm.prank(stranger);
        vm.expectRevert(PledgeVault.ZeroAmount.selector);
        vault.addBudget(id, 0);
        vm.prank(stranger);
        vm.expectRevert(PledgeVault.UnknownPledge.selector);
        vault.addBudget(99, 1);
    }

    // ───────────────────────────── checks ────────────────────────────────

    function test_requestCheckRevertsUntilOracleConfigured() public {
        uint256 id = _create(1, 1e18, 1e18);
        vm.prank(beneficiary);
        vm.expectRevert(PledgeVault.OracleNotConfigured.selector);
        vault.requestCheck(id, 0);
    }

    function test_requestCheckPaysIntakeFromBudget() public {
        _configure();
        uint256 id = _create(1, 1e18, 1e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);

        assertEq(imd.balanceOf(intake), PRICE);
        assertEq(vault.getPledge(id).budget, 1e18 - PRICE);
        PledgeVault.Milestone memory m = vault.getMilestone(id, 0);
        assertEq(m.attempts, 1);
        assertTrue(m.checkOpen);
        assertEq(m.openCheckPrice, PRICE);
    }

    function test_requestCheckGuards() public {
        _configure();
        uint256 id = _create(1, 1e18, PRICE);

        vm.prank(team);
        vm.expectRevert(PledgeVault.NotBeneficiary.selector);
        vault.requestCheck(id, 0);

        vm.prank(beneficiary);
        vm.expectRevert(PledgeVault.UnknownMilestone.selector);
        vault.requestCheck(id, 1);

        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        vm.prank(beneficiary);
        vm.expectRevert(PledgeVault.CheckAlreadyOpen.selector);
        vault.requestCheck(id, 0);

        // Answer "not kept", then the budget is empty.
        uint256 expiry = block.timestamp + 1 hours;
        vault.submitVerdict(id, 0, 1, false, expiry, _verdict(id, 0, 1, false, expiry, 2));
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.InsufficientBudget.selector, 0, PRICE));
        vault.requestCheck(id, 0);
    }

    function test_requestCheckAttemptsAreCapped() public {
        _configure();
        uint256 id = _create(1, 1e18, 10e18);
        for (uint8 a = 1; a <= 3; ++a) {
            vm.prank(beneficiary);
            vault.requestCheck(id, 0);
            uint256 expiry = block.timestamp + 1 hours;
            vault.submitVerdict(id, 0, a, false, expiry, _verdict(id, 0, a, false, expiry, 2));
        }
        vm.prank(beneficiary);
        vm.expectRevert(PledgeVault.AttemptsExhausted.selector);
        vault.requestCheck(id, 0);
        assertEq(vault.getPledge(id).budget, 10e18 - 3 * PRICE);
    }

    function test_requestCheckRefusedAfterGrace() public {
        _configure();
        uint256 id = _create(1, 1e18, 10e18);
        vm.warp(T0 + 30 days + 3 days + 1);
        vm.prank(beneficiary);
        vm.expectRevert(PledgeVault.GraceOver.selector);
        vault.requestCheck(id, 0);
    }

    function test_questionIsWrittenByTheVault() public {
        uint256 id = _create(2, 1e18, 0);
        string memory q = vault.question(id, 1);
        assertEq(
            q,
            string.concat(
                "KEPT pledge #1, milestone 2 of 2. Deadline (unix): ",
                vm.toString(T0 + 60 days),
                ". Was this delivered by the deadline? Milestone 2 shipped"
            )
        );
    }

    // ───────────────────────────── verdicts ──────────────────────────────

    function test_keptVerdictReleasesTrancheAndRefundsCheck() public {
        _configure();
        _attachFund(5e18);
        uint256 id = _create(2, 1_000e18, 1e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);

        uint256 expiry = block.timestamp + 1 hours;
        vm.expectEmit(true, true, true, true);
        emit PledgeVault.TrancheReleased(id, 0, beneficiary, 1_000e18);
        vault.submitVerdict(id, 0, 1, true, expiry, _verdict(id, 0, 1, true, expiry, 3));

        assertEq(kept.balanceOf(beneficiary), 1_000e18);
        assertEq(kept.balanceOf(address(vault)), 1_000e18);
        PledgeVault.Milestone memory m = vault.getMilestone(id, 0);
        assertEq(uint8(m.status), uint8(PledgeVault.Status.Kept));
        assertFalse(m.checkOpen);
        PledgeVault.Pledge memory p = vault.getPledge(id);
        assertEq(p.settled, 1);
        // The check was refunded into the budget: keeping a promise cost nothing.
        assertEq(p.budget, 1e18);
        assertEq(p.refunded, PRICE);
        assertEq(fund.balance(), 5e18 - PRICE);
    }

    function test_keptVerdictWithoutFundStillReleases() public {
        _configure();
        uint256 id = _create(1, 1_000e18, 1e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;
        vault.submitVerdict(id, 0, 1, true, expiry, _verdict(id, 0, 1, true, expiry, 2));
        assertEq(kept.balanceOf(beneficiary), 1_000e18);
        assertEq(vault.getPledge(id).budget, 1e18 - PRICE);
        assertEq(vault.getPledge(id).refunded, 0);
    }

    function test_refundIsPartialWhenFundIsShort() public {
        _configure();
        _attachFund(0.2e18);
        uint256 id = _create(1, 1e18, 1e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;
        vault.submitVerdict(id, 0, 1, true, expiry, _verdict(id, 0, 1, true, expiry, 2));
        assertEq(vault.getPledge(id).budget, 1e18 - PRICE + 0.2e18);
        assertEq(fund.balance(), 0);
    }

    function test_brokenVerdictKeepsTrancheLockedAndAllowsRetry() public {
        _configure();
        uint256 id = _create(1, 1_000e18, 2e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;
        vault.submitVerdict(id, 0, 1, false, expiry, _verdict(id, 0, 1, false, expiry, 2));

        PledgeVault.Milestone memory m = vault.getMilestone(id, 0);
        assertEq(uint8(m.status), uint8(PledgeVault.Status.Pending));
        assertFalse(m.checkOpen);
        assertEq(kept.balanceOf(address(vault)), 1_000e18);

        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        vault.submitVerdict(id, 0, 2, true, expiry, _verdict(id, 0, 2, true, expiry, 2));
        assertEq(kept.balanceOf(beneficiary), 1_000e18);
    }

    function test_verdictRejectsForgedOrInsufficientSignatures() public {
        _configure();
        uint256 id = _create(1, 1e18, 1e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = vault.verdictDigest(id, 0, 1, true, expiry);

        // Below quorum.
        bytes[] memory sigs1 = _verdict(id, 0, 1, true, expiry, 1);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.NotEnoughSignatures.selector, 1, 2));
        vault.submitVerdict(id, 0, 1, true, expiry, sigs1);

        // An outsider's signature.
        (, uint256 outsiderKey) = makeAddrAndKey("outsider");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(keys[0], digest);
        sigs[1] = _sign(outsiderKey, digest);
        address outsider = ECDSA.recover(digest, sigs[1]);
        if (outsider > panel[0]) {
            vm.expectRevert(abi.encodeWithSelector(PledgeVault.UnknownSigner.selector, outsider));
        } else {
            vm.expectRevert(PledgeVault.SignersNotAscending.selector);
        }
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);

        // The same panel member twice.
        sigs[1] = sigs[0];
        vm.expectRevert(PledgeVault.SignersNotAscending.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);

        // Malformed signature bytes.
        sigs[0] = hex"deadbeef";
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 4));
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);

        assertEq(kept.balanceOf(beneficiary), 0);
    }

    function test_verdictRejectsSignaturesOverOtherTerms() public {
        _configure();
        uint256 id = _create(1, 1e18, 1e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;

        // Signatures over a different outcome.
        bytes[] memory sigs2 = _verdict(id, 0, 1, false, expiry, 2);
        vm.expectRevert();
        vault.submitVerdict(id, 0, 1, true, expiry, sigs2);

        // Signatures over a different expiry.
        bytes[] memory sigs3 = _verdict(id, 0, 1, true, expiry + 1, 2);
        vm.expectRevert();
        vault.submitVerdict(id, 0, 1, true, expiry, sigs3);

        // Signatures over a different attempt.
        bytes[] memory sigs4 = _verdict(id, 0, 2, true, expiry, 2);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.AttemptMismatch.selector, 1, 2));
        vault.submitVerdict(id, 0, 2, true, expiry, sigs4);

        // Signatures over a different pledge's milestone.
        uint256 other = _create(1, 1e18, 1e18);
        bytes[] memory sigs5 = _verdict(other, 0, 1, true, expiry, 2);
        vm.expectRevert();
        vault.submitVerdict(id, 0, 1, true, expiry, sigs5);

        assertEq(kept.balanceOf(beneficiary), 0);
    }

    function test_verdictRejectsWhenNoCheckIsOpenOrAlreadySettled() public {
        _configure();
        uint256 id = _create(1, 1e18, 1e18);
        uint256 expiry = block.timestamp + 1 hours;
        bytes[] memory sigs6 = _verdict(id, 0, 1, true, expiry, 2);
        vm.expectRevert(PledgeVault.NoCheckOpen.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs6);

        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        bytes[] memory sigs = _verdict(id, 0, 1, true, expiry, 2);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);
        // Replay.
        vm.expectRevert(PledgeVault.NotPending.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);
    }

    function test_verdictRejectsExpiredOrLate() public {
        _configure();
        uint256 id = _create(1, 1e18, 1e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);

        uint256 expiry = block.timestamp + 1 hours;
        bytes[] memory sigs = _verdict(id, 0, 1, true, expiry, 2);
        vm.warp(expiry + 1);
        vm.expectRevert(PledgeVault.VerdictExpired.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);

        // A long-lived signature still cannot land after the grace period.
        uint256 lateExpiry = T0 + 365 days;
        sigs = _verdict(id, 0, 1, true, lateExpiry, 2);
        vm.warp(T0 + 30 days + 3 days + 1);
        vm.expectRevert(PledgeVault.GraceOver.selector);
        vault.submitVerdict(id, 0, 1, true, lateExpiry, sigs);
    }

    function test_verdictAcceptedWithinGraceAfterDeadline() public {
        _configure();
        uint256 id = _create(1, 1e18, 1e18);
        vm.warp(T0 + 30 days + 2 days);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;
        vault.submitVerdict(id, 0, 1, true, expiry, _verdict(id, 0, 1, true, expiry, 2));
        assertEq(kept.balanceOf(beneficiary), 1e18);
    }

    // ─────────────────────────── missed deadlines ────────────────────────

    function test_settleMissedBurnsAfterGrace() public {
        uint256 id = _create(2, 1_000e18, 0);
        uint256 supplyBefore = kept.totalSupply();

        vm.expectRevert(PledgeVault.GraceNotOver.selector);
        vault.settleMissed(id, 0);
        vm.warp(T0 + 30 days + 3 days);
        vm.expectRevert(PledgeVault.GraceNotOver.selector);
        vault.settleMissed(id, 0);

        vm.warp(T0 + 30 days + 3 days + 1);
        vm.prank(stranger);
        vm.expectEmit(true, true, true, true);
        emit PledgeVault.TrancheBurned(id, 0, 1_000e18, true);
        vault.settleMissed(id, 0);

        assertEq(kept.totalSupply(), supplyBefore - 1_000e18);
        assertEq(kept.balanceOf(address(vault)), 1_000e18);
        assertEq(uint8(vault.getMilestone(id, 0).status), uint8(PledgeVault.Status.Burned));
        assertEq(vault.getPledge(id).settled, 1);
        assertEq(vault.stranded(address(kept)), 0);

        vm.expectRevert(PledgeVault.NotPending.selector);
        vault.settleMissed(id, 0);
        // The second milestone is still within its own deadline.
        vm.expectRevert(PledgeVault.GraceNotOver.selector);
        vault.settleMissed(id, 1);
    }

    function test_settleMissedClosesAnOpenCheckWithoutRefund() public {
        _configure();
        uint256 id = _create(1, 1e18, 1e18);
        vm.warp(T0 + 30 days + 3 days);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        vm.warp(T0 + 30 days + 3 days + 1);
        vault.settleMissed(id, 0);
        PledgeVault.Milestone memory m = vault.getMilestone(id, 0);
        assertFalse(m.checkOpen);
        assertEq(m.openCheckPrice, 0);
        assertEq(vault.getPledge(id).budget, 1e18 - PRICE);

        uint256 expiry = block.timestamp + 1 hours;
        bytes[] memory sigs7 = _verdict(id, 0, 1, true, expiry, 2);
        vm.expectRevert(PledgeVault.NotPending.selector);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs7);
    }

    function test_settleMissedStrandsTokensWithoutARealBurn() public {
        MockERC20 plain = new MockERC20("Plain", "PLN");
        FakeBurnToken fake = new FakeBurnToken();
        plain.mint(team, 10e18);
        fake.mint(team, 10e18);
        vm.startPrank(team);
        plain.approve(address(vault), type(uint256).max);
        fake.approve(address(vault), type(uint256).max);
        uint256 a = vault.createPledge(address(plain), beneficiary, "no burn", _milestones(1, 10e18), 0);
        uint256 b = vault.createPledge(address(fake), beneficiary, "fake burn", _milestones(1, 10e18), 0);
        vm.stopPrank();

        vm.warp(T0 + 30 days + 3 days + 1);
        vm.expectEmit(true, true, true, true);
        emit PledgeVault.TrancheBurned(a, 0, 10e18, false);
        vault.settleMissed(a, 0);
        vault.settleMissed(b, 0);

        assertEq(vault.stranded(address(plain)), 10e18);
        assertEq(vault.stranded(address(fake)), 10e18);
        assertEq(plain.balanceOf(address(vault)), 10e18);
        assertEq(fake.balanceOf(address(vault)), 10e18);
        assertEq(uint8(vault.getMilestone(a, 0).status), uint8(PledgeVault.Status.Burned));
    }

    // ───────────────────────────── budgets ───────────────────────────────

    function test_reclaimBudgetOnlyOnceEverythingIsSettled() public {
        _configure();
        uint256 id = _create(2, 1e18, 3e18);
        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;
        vault.submitVerdict(id, 0, 1, true, expiry, _verdict(id, 0, 1, true, expiry, 2));

        vm.expectRevert(PledgeVault.NotSettled.selector);
        vault.reclaimBudget(id);

        vm.warp(T0 + 60 days + 3 days + 1);
        vault.settleMissed(id, 1);
        uint256 teamBefore = imd.balanceOf(team);
        vm.prank(stranger);
        vault.reclaimBudget(id);
        assertEq(imd.balanceOf(team) - teamBefore, 3e18 - PRICE);
        assertEq(vault.getPledge(id).budget, 0);

        vm.expectRevert(PledgeVault.ZeroAmount.selector);
        vault.reclaimBudget(id);
    }

    // ────────────────────────── oracle configuration ─────────────────────

    function test_firstOracleConfigAppliesAtOnce() public {
        vm.prank(owner);
        vault.scheduleOracleConfig(intake, PRICE, panel, 2);
        assertEq(vault.pendingReadyAt(), block.timestamp);
        vault.applyOracleConfig();
        assertEq(vault.intake(), intake);
        assertEq(vault.checkPrice(), PRICE);
        assertEq(vault.quorum(), 2);
        address[] memory s = vault.signers();
        assertEq(s.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertTrue(vault.isSigner(panel[i]));
        }
        assertEq(vault.pendingReadyAt(), 0);
    }

    function test_laterOracleConfigWaitsSevenDays() public {
        _configure();
        address[] memory next = new address[](1);
        next[0] = makeAddr("new-signer");
        address newIntake = makeAddr("new-intake");

        vm.prank(owner);
        vault.scheduleOracleConfig(newIntake, 0.1e18, next, 1);
        uint64 readyAt = uint64(block.timestamp + 7 days);
        assertEq(vault.pendingReadyAt(), readyAt);

        vm.expectRevert(abi.encodeWithSelector(PledgeVault.NoticeNotOver.selector, readyAt));
        vault.applyOracleConfig();
        // The old oracle keeps working during the notice.
        assertEq(vault.intake(), intake);
        assertTrue(vault.isSigner(panel[0]));

        vm.warp(readyAt);
        vm.prank(stranger);
        vault.applyOracleConfig();
        assertEq(vault.intake(), newIntake);
        assertEq(vault.checkPrice(), 0.1e18);
        assertEq(vault.quorum(), 1);
        assertEq(vault.signers().length, 1);
        assertTrue(vault.isSigner(next[0]));
        for (uint256 i; i < 3; ++i) {
            assertFalse(vault.isSigner(panel[i]));
        }
    }

    function test_oldPanelCannotSignAfterRotation() public {
        _configure();
        uint256 id = _create(1, 1e18, 5e18);
        (address fresh, uint256 freshKey) = makeAddrAndKey("fresh");
        address[] memory next = new address[](1);
        next[0] = fresh;
        vm.prank(owner);
        vault.scheduleOracleConfig(intake, PRICE, next, 1);
        vm.warp(block.timestamp + 7 days);
        vault.applyOracleConfig();

        vm.prank(beneficiary);
        vault.requestCheck(id, 0);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = vault.verdictDigest(id, 0, 1, true, expiry);
        bytes[] memory old = new bytes[](1);
        old[0] = _sign(keys[0], digest);
        vm.expectRevert(abi.encodeWithSelector(PledgeVault.UnknownSigner.selector, panel[0]));
        vault.submitVerdict(id, 0, 1, true, expiry, old);

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(freshKey, digest);
        vault.submitVerdict(id, 0, 1, true, expiry, sigs);
        assertEq(kept.balanceOf(beneficiary), 1e18);
    }

    function test_oracleConfigValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(PledgeVault.ZeroAddress.selector);
        vault.scheduleOracleConfig(address(0), PRICE, panel, 2);
        vm.expectRevert(PledgeVault.PriceTooHigh.selector);
        vault.scheduleOracleConfig(intake, PRICE + 1, panel, 2);
        vm.expectRevert(PledgeVault.BadPanel.selector);
        vault.scheduleOracleConfig(intake, PRICE, new address[](0), 1);
        vm.expectRevert(PledgeVault.BadPanel.selector);
        vault.scheduleOracleConfig(intake, PRICE, new address[](17), 1);
        address[] memory dup = new address[](2);
        dup[0] = panel[0];
        dup[1] = panel[0];
        vm.expectRevert(PledgeVault.BadPanel.selector);
        vault.scheduleOracleConfig(intake, PRICE, dup, 1);
        dup[1] = address(0);
        vm.expectRevert(PledgeVault.ZeroAddress.selector);
        vault.scheduleOracleConfig(intake, PRICE, dup, 1);
        vm.expectRevert(PledgeVault.BadQuorum.selector);
        vault.scheduleOracleConfig(intake, PRICE, panel, 0);
        vm.expectRevert(PledgeVault.BadQuorum.selector);
        vault.scheduleOracleConfig(intake, PRICE, panel, 4);
        vm.stopPrank();

        vm.expectRevert(PledgeVault.NothingPending.selector);
        vault.applyOracleConfig();
        vm.prank(owner);
        vm.expectRevert(PledgeVault.NothingPending.selector);
        vault.cancelOracleConfig();
    }

    function test_onlyOwnerSchedulesOrCancels() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.scheduleOracleConfig(intake, PRICE, panel, 2);

        vm.prank(owner);
        vault.scheduleOracleConfig(intake, PRICE, panel, 2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.cancelOracleConfig();

        vm.prank(owner);
        vault.cancelOracleConfig();
        assertEq(vault.pendingReadyAt(), 0);
        assertEq(vault.pendingOracleConfig().signers.length, 0);
        vm.expectRevert(PledgeVault.NothingPending.selector);
        vault.applyOracleConfig();
    }

    function test_rescheduleReplacesPending() public {
        vm.startPrank(owner);
        vault.scheduleOracleConfig(intake, PRICE, panel, 2);
        address[] memory one = new address[](1);
        one[0] = panel[1];
        vault.scheduleOracleConfig(intake, 0.25e18, one, 1);
        vm.stopPrank();
        PledgeVault.OracleConfig memory pending = vault.pendingOracleConfig();
        assertEq(pending.signers.length, 1);
        assertEq(pending.checkPrice, 0.25e18);
        vault.applyOracleConfig();
        assertEq(vault.signers().length, 1);
        assertFalse(vault.isSigner(panel[0]));
    }

    function test_ownerIsTheConstructorArgumentAndTwoStep() public {
        assertEq(vault.owner(), owner);
        address next = makeAddr("next-owner");
        vm.prank(owner);
        vault.transferOwnership(next);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), next);
        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next);
    }

    function test_constructorRejectsZeroImd() public {
        vm.expectRevert(PledgeVault.ZeroAddress.selector);
        new PledgeVault(owner, address(0));
    }

    function test_setRefereeFundOnceAndMatching() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setRefereeFund(address(fund));

        RefereeFund other = new RefereeFund(address(imd), stranger);
        vm.prank(owner);
        vm.expectRevert(PledgeVault.FundVaultMismatch.selector);
        vault.setRefereeFund(address(other));

        vm.prank(owner);
        vm.expectRevert(PledgeVault.ZeroAddress.selector);
        vault.setRefereeFund(address(0));

        vm.prank(owner);
        vault.setRefereeFund(address(fund));
        assertEq(address(vault.refereeFund()), address(fund));

        vm.prank(owner);
        vm.expectRevert(PledgeVault.FundAlreadySet.selector);
        vault.setRefereeFund(address(fund));
    }

    // ────────────────────────── nothing else moves ───────────────────────

    function test_ownerHasNoWayToMoveLockedTokensOrBudgets() public {
        _configure();
        uint256 id = _create(1, 1_000e18, 1e18);
        string[6] memory signatures = [
            "withdraw(address,uint256)",
            "rescue(address,uint256)",
            "sweep(address)",
            "pause()",
            "upgradeTo(address)",
            "cancelPledge(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(vault).call(abi.encodeWithSignature(signatures[i], owner, id));
            assertFalse(ok, signatures[i]);
        }
        assertEq(kept.balanceOf(address(vault)), 1_000e18);
        assertEq(imd.balanceOf(address(vault)), 1e18);
    }

    // ─────────────────────────────── fuzz ────────────────────────────────

    function testFuzz_fundsAreConservedThroughALifecycle(uint256 amount, uint256 budget, uint8 outcomes) public {
        amount = bound(amount, 1, 1_000_000e18);
        budget = bound(budget, 3 * PRICE, 100e18);
        _configure();
        _attachFund(10e18);
        uint256 supply = kept.totalSupply();
        uint256 id = _create(3, amount, budget);

        uint256 released;
        uint256 burned;
        uint256 refunded;
        for (uint256 m; m < 3; ++m) {
            bool keep = (outcomes >> m) & 1 == 1;
            if (keep) {
                vm.prank(beneficiary);
                vault.requestCheck(id, m);
                uint256 expiry = block.timestamp + 1 hours;
                uint256 fundBefore = fund.balance();
                vault.submitVerdict(id, m, 1, true, expiry, _verdict(id, m, 1, true, expiry, 2));
                released += amount;
                refunded += fundBefore - fund.balance();
            } else {
                vm.warp(T0 + (m + 1) * 30 days + 3 days + 1);
                vault.settleMissed(id, m);
                burned += amount;
            }
        }
        assertEq(kept.balanceOf(beneficiary), released);
        assertEq(kept.totalSupply(), supply - burned);
        assertEq(kept.balanceOf(address(vault)), 0);

        uint256 spent = PRICE * (released / amount);
        uint256 teamBefore = imd.balanceOf(team);
        vault.reclaimBudget(id);
        assertEq(imd.balanceOf(team) - teamBefore, budget - spent + refunded);
        assertEq(imd.balanceOf(intake), spent);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(refunded, spent);
    }
}
