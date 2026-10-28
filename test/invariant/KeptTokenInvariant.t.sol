// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeptToken} from "src/KeptToken.sol";
import {TokenSignatures} from "../helpers/TokenSignatures.sol";

/// @dev All supply is held by four actors; only the selected actions can move it.
/// Ghost balances, allowances and nonces are driven by inputs, never copied back from token state.
contract KeptTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant ACTORS = 4;
    KeptToken public immutable token;
    address[4] public actors;
    uint256[4] private keys;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;
    uint256 public burned;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public burns;
    uint256 public permits;
    uint256 public rejectedCalls;

    constructor() {
        token = new KeptToken();
        for (uint256 i; i < ACTORS; ++i) {
            (actors[i], keys[i]) = makeAddrAndKey(string.concat("token-invariant-", vm.toString(i)));
            assertTrue(token.transfer(actors[i], SUPPLY / ACTORS));
            expectedBalance[actors[i]] = SUPPLY / ACTORS;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 raw) external {
        address from = actors[fromSeed % ACTORS];
        address to = actors[toSeed % ACTORS];
        uint256 amount = _amount(raw, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 raw) external {
        address owner = actors[ownerSeed % ACTORS];
        address spender = actors[spenderSeed % ACTORS];
        uint256 value = raw % 4 == 0 ? type(uint256).max : _amount(raw, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        expectedAllowance[owner][spender] = value;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 raw) external {
        address owner = actors[ownerSeed % ACTORS];
        address spender = actors[spenderSeed % ACTORS];
        address to = actors[toSeed % ACTORS];
        uint256 available = expectedBalance[owner];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 amount = _amount(raw, available < allowance ? available : allowance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _spendAllowance(owner, spender, amount);
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        ++delegatedTransfers;
    }

    function burn(uint256 ownerSeed, uint256 raw) external {
        address owner = actors[ownerSeed % ACTORS];
        uint256 amount = _amount(raw, expectedBalance[owner]);
        vm.prank(owner);
        token.burn(amount);
        expectedBalance[owner] -= amount;
        burned += amount;
        ++burns;
    }

    function burnFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 raw) external {
        address owner = actors[ownerSeed % ACTORS];
        address spender = actors[spenderSeed % ACTORS];
        uint256 available = expectedBalance[owner];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 amount = _amount(raw, available < allowance ? available : allowance);
        vm.prank(spender);
        token.burnFrom(owner, amount);
        _spendAllowance(owner, spender, amount);
        expectedBalance[owner] -= amount;
        burned += amount;
        ++burns;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 raw) external {
        uint256 ownerIndex = ownerSeed % ACTORS;
        address owner = actors[ownerIndex];
        address spender = actors[spenderSeed % ACTORS];
        uint256 value = raw % 4 == 0 ? type(uint256).max : _amount(raw, SUPPLY);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = TokenSignatures.digest(
            address(token), block.chainid, owner, spender, value, expectedNonce[owner], deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[ownerIndex], digest);
        token.permit(owner, spender, value, deadline, v, r, s);
        ++expectedNonce[owner];
        expectedAllowance[owner][spender] = value;
        ++permits;
    }

    function rejectOverdraw(uint256 ownerSeed, bool delegated, bool burning) external {
        address owner = actors[ownerSeed % ACTORS];
        address spender = actors[(ownerSeed % ACTORS + 1) % ACTORS];
        uint256 held = expectedBalance[owner];
        uint256 amount = held + 1;
        if (delegated) {
            vm.prank(owner);
            token.approve(spender, amount);
            expectedAllowance[owner][spender] = amount;
        }
        vm.prank(delegated ? spender : owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        if (burning) {
            if (delegated) token.burnFrom(owner, amount);
            else token.burn(amount);
        } else {
            if (delegated) token.transferFrom(owner, spender, amount);
            else token.transfer(spender, amount);
        }
        ++rejectedCalls;
    }

    function rejectRevokedAllowance(uint256 ownerSeed, bool burning) external {
        address owner = actors[ownerSeed % ACTORS];
        address spender = actors[(ownerSeed % ACTORS + 1) % ACTORS];
        vm.prank(owner);
        token.approve(spender, 0);
        expectedAllowance[owner][spender] = 0;
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        if (burning) token.burnFrom(owner, 1);
        else token.transferFrom(owner, spender, 1);
        ++rejectedCalls;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        if (expectedAllowance[owner][spender] != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    /// @dev Give zero, one wei and full-balance actions frequent representation.
    function _amount(uint256 raw, uint256 maximum) private pure returns (uint256) {
        if (maximum == 0 || raw % 8 == 0) return 0;
        if (raw % 8 == 1) return 1;
        if (raw % 8 == 2) return maximum;
        return bound(raw, 0, maximum);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract KeptTokenInvariantTest is Test {
    KeptTokenHandler handler;
    KeptToken token;

    function setUp() public {
        handler = new KeptTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.burnFrom.selector;
        selectors[5] = handler.permit.selector;
        selectors[6] = handler.rejectOverdraw.selector;
        selectors[7] = handler.rejectRevokedAllowance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_supplyEqualsTrackedBalancesAndAuthorizedBurns() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "unexpected actor balance");
            sum += token.balanceOf(actor);
        }
        assertEq(token.totalSupply(), sum, "supply must equal all balances");
        assertEq(token.totalSupply() + handler.burned(), 1_000_000_000e18, "mint or unauthorized burn");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_allowancesAndNoncesMatchAuthorizedActions() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.nonces(owner), handler.expectedNonce(owner));
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    /// @dev A deterministic mixed sequence checks that the harness reaches nonzero delegated actions.
    function test_handlerExercisesTransferBurnPermitAndFailures() public {
        handler.permit(0, 1, 0);
        handler.transferFrom(0, 1, 2, 1);
        handler.burnFrom(0, 1, 1);
        handler.transfer(2, 3, 1);
        handler.burn(3, 1);
        handler.rejectOverdraw(2, true, false);
        handler.rejectRevokedAllowance(0, true);
        invariant_supplyEqualsTrackedBalancesAndAuthorizedBurns();
        invariant_allowancesAndNoncesMatchAuthorizedActions();
        assertEq(handler.burned(), 2);
        assertEq(handler.permits(), 1);
        assertEq(handler.delegatedTransfers(), 1);
        assertEq(handler.rejectedCalls(), 2);
    }
}
