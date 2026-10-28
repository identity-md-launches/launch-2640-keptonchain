// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {KeptToken} from "src/KeptToken.sol";
import {TokenSignatures} from "./helpers/TokenSignatures.sol";

/// forge-config: default.fuzz.runs = 1000
contract KeptTokenPropertiesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    KeptToken token;
    address holder;
    uint256 holderKey;
    address spender;
    address recipient;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new KeptToken();
        (holder, holderKey) = makeAddrAndKey("property-holder");
        spender = makeAddr("property-spender");
        recipient = makeAddr("property-recipient");
    }

    function test_constructorEmitsOnlyMintToActualDeployer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        KeptToken fresh = new KeptToken();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
        assertEq(fresh.balanceOf(address(fresh)), 0);
        assertEq(fresh.balanceOf(address(0)), 0);
    }

    function test_zeroAndOneWeiTransfersAndFullSupplyRoundTrip() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, 0));
        assertTrue(token.transfer(holder, 1));
        vm.prank(holder);
        assertTrue(token.transfer(address(this), 1));
        assertTrue(token.transfer(holder, SUPPLY));
        vm.prank(holder);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToZeroRejectsEvenZeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approveOverwritesAndRevokesAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, type(uint256).max);
        assertTrue(token.approve(spender, type(uint256).max));
        assertTrue(token.approve(spender, 1));
        assertEq(token.allowance(address(this), spender), 1);
        assertTrue(token.approve(spender, 0));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_failedTransferFromPreservesAllowanceAndBalances() public {
        token.transfer(holder, 1);
        vm.prank(holder);
        token.approve(spender, 2);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 1, 2));
        token.transferFrom(holder, recipient, 2);
        assertEq(token.allowance(holder, spender), 2);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(holder, address(0), 1);
        assertEq(token.allowance(holder, spender), 2);
        assertEq(token.balanceOf(holder), 1);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_failedBurnFromPreservesAllowanceAndSupply() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        token.burnFrom(holder, 1);
        assertEq(token.allowance(holder, spender), type(uint256).max - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnZeroOneAndEntireSupply() public {
        vm.prank(holder);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(0), 1);
        token.burn(1);
        assertEq(token.totalSupply(), SUPPLY - 1);
        token.burn(SUPPLY - 1);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
        assertTrue(token.transfer(holder, 0));
    }

    function test_maximumTransferAndBurnRevertWithoutOverflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(holder, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.burn(type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_infiniteAllowanceSurvivesTransferFromAndBurnFrom() public {
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(address(this), holder, 1);
        token.burnFrom(address(this), SUPPLY - 1);
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(holder), 1);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testFuzz_selfTransferIsIdentityButDelegatedSelfTransferSpendsAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(holder, amount);
        vm.prank(holder);
        assertTrue(token.transfer(holder, amount));
        assertEq(token.balanceOf(holder), amount);
        vm.prank(holder);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, holder, amount));
        assertEq(token.balanceOf(holder), amount);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAndBurnShareOneFiniteAllowance(uint256 approved, uint256 moved) public {
        approved = bound(approved, 1, SUPPLY);
        moved = bound(moved, 0, approved);
        token.approve(spender, approved);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), recipient, moved));
        token.burnFrom(address(this), approved - moved);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.burnFrom(address(this), 1);
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - approved);
        assertEq(token.balanceOf(recipient), moved);
        assertEq(token.totalSupply(), SUPPLY - (approved - moved));
    }

    function testFuzz_allowanceOneShortCannotTransferOrBurn(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.approve(spender, amount - 1);
        vm.startPrank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount - 1, amount)
        );
        token.transferFrom(address(this), recipient, amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount - 1, amount)
        );
        token.burnFrom(address(this), amount);
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), amount - 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_relayedPermitUsesIndependentDomainAndAcceptsDeadlineEquality(uint256 value) public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(token), block.chainid, spender, value, 0, deadline);
        vm.prank(recipient);
        token.permit(holder, spender, value, deadline, v, r, s);
        assertEq(token.DOMAIN_SEPARATOR(), TokenSignatures.domain(address(token), block.chainid));
        assertEq(token.allowance(holder, spender), value);
        assertEq(token.nonces(holder), 1);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_permitRejectsWrongSignerWithoutConsumingNonce() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrong-permit-signer");
        bytes32 digest =
            TokenSignatures.digest(address(token), block.chainid, holder, spender, 1, 0, vm.getBlockTimestamp());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(wrongKey), holder));
        token.permit(holder, spender, 1, vm.getBlockTimestamp(), v, r, s);
        _assertPermitUnchanged();
    }

    function test_permitRejectsAnotherContractAndAnotherChain() public {
        KeptToken other = new KeptToken();
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(other), block.chainid, spender, 1, 0, vm.getBlockTimestamp());
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 1, vm.getBlockTimestamp(), v, r, s);
        (v, r, s) = _sign(address(token), block.chainid, spender, 1, 0, vm.getBlockTimestamp());
        uint256 nextChain = block.chainid + 1;
        vm.chainId(nextChain);
        assertEq(token.DOMAIN_SEPARATOR(), TokenSignatures.domain(address(token), nextChain));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 1, vm.getBlockTimestamp(), v, r, s);
        _assertPermitUnchanged();
    }

    function test_permitBindsSpenderValueNonceAndDeadline() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(token), block.chainid, spender, 1, 0, vm.getBlockTimestamp());
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, recipient, 1, vm.getBlockTimestamp(), v, r, s);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 2, vm.getBlockTimestamp(), v, r, s);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 1, vm.getBlockTimestamp() + 1, v, r, s);
        (v, r, s) = _sign(address(token), block.chainid, spender, 1, 1, vm.getBlockTimestamp());
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 1, vm.getBlockTimestamp(), v, r, s);
        _assertPermitUnchanged();
        assertEq(token.allowance(holder, recipient), 0);
    }

    function test_permitRejectsMalleableSignatureAndZeroSpender() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(token), block.chainid, spender, 1, 0, vm.getBlockTimestamp());
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes32 highS = bytes32(curveOrder - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(holder, spender, 1, vm.getBlockTimestamp(), v == 27 ? 28 : 27, r, highS);
        (v, r, s) = _sign(address(token), block.chainid, address(0), 1, 0, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(holder, address(0), 1, vm.getBlockTimestamp(), v, r, s);
        _assertPermitUnchanged();
    }

    function test_permitCannotReplayAfterAllowanceRevocation() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(token), block.chainid, spender, 1, 0, vm.getBlockTimestamp());
        token.permit(holder, spender, 1, vm.getBlockTimestamp(), v, r, s);
        vm.prank(holder);
        token.approve(spender, 0);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(holder, spender, 1, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.nonces(holder), 1);
        assertEq(token.allowance(holder, spender), 0);
    }

    function _sign(
        address verifyingContract,
        uint256 chain,
        address approved,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8, bytes32, bytes32) {
        return vm.sign(
            holderKey, TokenSignatures.digest(verifyingContract, chain, holder, approved, value, nonce, deadline)
        );
    }

    function _assertPermitUnchanged() internal view {
        assertEq(token.nonces(holder), 0);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
