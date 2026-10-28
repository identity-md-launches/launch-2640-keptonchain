// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RefereeFund} from "src/RefereeFund.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract RefereeFundFailurePathsTest is Test {
    MockERC20 imd;
    RefereeFund fund;
    address vault;
    address donor;

    function setUp() public {
        imd = new MockERC20("Test IMD", "IMD");
        vault = makeAddr("failure-vault");
        donor = makeAddr("failure-donor");
        fund = new RefereeFund(address(imd), vault);
        imd.mint(donor, 10);
    }

    function test_failedDonationDoesNotInflateTotalDonated() public {
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 0, 1));
        fund.donate(1);
        assertEq(fund.totalDonated(), 0);
        vm.prank(donor);
        imd.approve(address(fund), 11);
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, donor, 10, 11));
        fund.donate(11);
        assertEq(fund.totalDonated(), 0);
        assertEq(fund.balance(), 0);
        assertEq(imd.allowance(donor, address(fund)), 11);
        assertEq(imd.balanceOf(donor), 10);
    }

    function test_directDonationAndRefillAfterExhaustionRemainRefundable() public {
        vm.prank(donor);
        imd.transfer(address(fund), 4);
        assertEq(fund.totalDonated(), 0, "direct transfers are not donate calls");
        vm.prank(vault);
        assertEq(fund.refund(type(uint256).max), 4);
        assertEq(fund.balance(), 0);
        vm.startPrank(donor);
        imd.approve(address(fund), 6);
        fund.donate(6);
        vm.stopPrank();
        vm.prank(vault);
        assertEq(fund.refund(0), 0);
        assertEq(fund.balance(), 6);
        vm.prank(vault);
        assertEq(fund.refund(6), 6);
        vm.prank(vault);
        assertEq(fund.refund(type(uint256).max), 0);
        assertEq(fund.totalDonated(), 6);
        assertEq(fund.totalRefunded(), 10);
        assertEq(imd.balanceOf(vault), 10);
    }

    function test_unauthorizedRefundCannotChangeAccountingEvenForZero() public {
        vm.prank(donor);
        imd.transfer(address(fund), 10);
        vm.prank(donor);
        vm.expectRevert(RefereeFund.NotVault.selector);
        fund.refund(0);
        vm.prank(donor);
        vm.expectRevert(RefereeFund.NotVault.selector);
        fund.refund(type(uint256).max);
        assertEq(fund.totalRefunded(), 0);
        assertEq(fund.balance(), 10);
        assertEq(imd.balanceOf(donor), 0);
        assertEq(imd.balanceOf(vault), 0);
    }
}
