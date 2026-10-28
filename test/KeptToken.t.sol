// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {KeptToken} from "../src/KeptToken.sol";

/// @notice Deploys the token the way the launch factory does, so `msg.sender` in the constructor is a contract.
contract FactoryStandIn {
    function deploy() external returns (KeptToken) {
        return new KeptToken();
    }
}

contract KeptTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    FactoryStandIn factory;
    KeptToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new FactoryStandIn();
        token = factory.deploy();
    }

    function test_metadata() public view {
        assertEq(token.name(), "keptonchain");
        assertEq(token.symbol(), "KEPT");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_noMintFunctionExists() public {
        bytes[3] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("mint(uint256)", 1),
            abi.encodeWithSignature("setMinter(address)", alice)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "an admin selector was answered");
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferMovesExactAmount() public {
        vm.prank(address(factory));
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 400e18));
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.balanceOf(bob), 400e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsBeyondBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_holderCanBurnOwnTokens() public {
        vm.prank(address(factory));
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.burn(4e18);
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.totalSupply(), SUPPLY - 4e18);
    }

    function test_burnFromNeedsAllowance() public {
        vm.prank(address(factory));
        token.transfer(alice, 10e18);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1e18)
        );
        token.burnFrom(alice, 1e18);
        assertEq(token.balanceOf(alice), 10e18);
    }

    function test_transferFromNeedsAllowance() public {
        vm.prank(address(factory));
        token.transfer(alice, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_permitApprovesAndCannotReplay() public {
        (address owner, uint256 key) = makeAddrAndKey("permit-owner");
        vm.prank(address(factory));
        token.transfer(owner, 5e18);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                5e18,
                token.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        token.permit(owner, bob, 5e18, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 5e18);
        assertEq(token.nonces(owner), 1);

        vm.expectRevert();
        token.permit(owner, bob, 5e18, deadline, v, r, s);

        vm.prank(bob);
        token.transferFrom(owner, bob, 5e18);
        assertEq(token.balanceOf(bob), 5e18);
    }

    function test_permitRejectsExpired() public {
        (address owner, uint256 key) = makeAddrAndKey("permit-owner");
        uint256 deadline = block.timestamp - 1;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                1,
                0,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, bob, 1, deadline, v, r, s);
    }

    function testFuzz_transfersConserveSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(address(factory));
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_burnShrinksSupplyExactly(uint256 held, uint256 burned) public {
        held = bound(held, 1, SUPPLY);
        burned = bound(burned, 0, held);
        vm.prank(address(factory));
        token.transfer(alice, held);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.balanceOf(alice), held - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }
}
