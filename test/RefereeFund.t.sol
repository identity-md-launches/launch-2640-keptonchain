// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RefereeFund} from "../src/RefereeFund.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract RefereeFundTest is Test {
    MockERC20 imd;
    RefereeFund fund;
    address vault = makeAddr("vault");
    address donor = makeAddr("donor");

    function setUp() public {
        imd = new MockERC20("IMD", "IMD");
        fund = new RefereeFund(address(imd), vault);
        imd.mint(donor, 100e18);
        vm.prank(donor);
        imd.approve(address(fund), type(uint256).max);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(RefereeFund.ZeroAddress.selector);
        new RefereeFund(address(0), vault);
        vm.expectRevert(RefereeFund.ZeroAddress.selector);
        new RefereeFund(address(imd), address(0));
    }

    function test_donateMovesImdAndCounts() public {
        vm.prank(donor);
        fund.donate(10e18);
        assertEq(fund.balance(), 10e18);
        assertEq(fund.totalDonated(), 10e18);
        assertEq(imd.balanceOf(donor), 90e18);
    }

    function test_donateRejectsZero() public {
        vm.prank(donor);
        vm.expectRevert(RefereeFund.ZeroAmount.selector);
        fund.donate(0);
    }

    function test_onlyVaultRefunds() public {
        vm.prank(donor);
        fund.donate(10e18);
        vm.prank(donor);
        vm.expectRevert(RefereeFund.NotVault.selector);
        fund.refund(1e18);
    }

    function test_refundPaysWhatItCan() public {
        vm.prank(donor);
        fund.donate(3e18);
        vm.prank(vault);
        uint256 paid = fund.refund(5e18);
        assertEq(paid, 3e18);
        assertEq(imd.balanceOf(vault), 3e18);
        assertEq(fund.balance(), 0);
        assertEq(fund.totalRefunded(), 3e18);

        vm.prank(vault);
        assertEq(fund.refund(1e18), 0);
    }

    function testFuzz_refundNeverExceedsRequestOrBalance(uint256 donated, uint256 requested) public {
        donated = bound(donated, 0, 100e18);
        if (donated > 0) {
            vm.prank(donor);
            fund.donate(donated);
        }
        vm.prank(vault);
        uint256 paid = fund.refund(requested);
        assertLe(paid, requested);
        assertLe(paid, donated);
        assertEq(paid, requested < donated ? requested : donated);
        assertEq(imd.balanceOf(vault), paid);
    }
}
