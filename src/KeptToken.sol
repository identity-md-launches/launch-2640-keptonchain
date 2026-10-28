// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title keptonchain (KEPT)
/// @notice A plain, fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`, the launch factory). Nothing can mint afterwards: there is no owner, no
/// minter role, no pause, no blocklist and no transfer rule. Holders may burn their own tokens, and
/// the pledge vault burns the tranches of missed milestones with `burn`.
/// @dev KEPT's own product rule is "plain ERC-20 only": the pledge vault refuses tokens whose transfers
/// arrive short (taxes, fees) and its README tells teams not to lock rebasing or decaying tokens, so
/// the token itself has none of them. ERC-2612 `permit` is included so
/// a team can approve the vault and lock tokens in a single transaction.
contract KeptToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice Token name, also the EIP-712 domain name for `permit`.
    string internal constant TOKEN_NAME = "keptonchain";
    /// @notice Token symbol.
    string internal constant TOKEN_SYMBOL = "KEPT";
    /// @notice Fixed total supply: 1,000,000,000 KEPT in 18-decimal minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
