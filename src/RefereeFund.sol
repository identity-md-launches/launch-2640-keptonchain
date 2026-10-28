// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Referee Fund
/// @notice Holds IMD and refunds the oracle check of every milestone a team keeps, when it can.
/// Keeping a promise costs nothing; breaking one means the team paid for its own verdict.
/// @dev Anyone may donate IMD. Only the pledge vault may draw from it, and only as a refund of a
/// check it has actually paid for a kept milestone. A refund never reverts for lack of funds: it
/// pays what it can and the vault records what was refunded. There is no owner and no withdrawal.
/// The site describes feeding this fund from a share of KEPT/IMD pool fees; that needs a pool
/// hook, which this launch does not deploy (see README), so the fund is fed by donations.
contract RefereeFund {
    using SafeERC20 for IERC20;

    /// @notice The paired currency checks are paid in (IMD on Ethereum).
    IERC20 public immutable imd;
    /// @notice The only contract allowed to draw refunds.
    address public immutable vault;

    /// @notice Total IMD ever donated.
    uint256 public totalDonated;
    /// @notice Total IMD ever refunded to the vault.
    uint256 public totalRefunded;

    event Donated(address indexed from, uint256 amount);
    event Refunded(uint256 requested, uint256 paid);

    error NotVault();
    error ZeroAddress();
    error ZeroAmount();

    constructor(address imd_, address vault_) {
        if (imd_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        imd = IERC20(imd_);
        vault = vault_;
    }

    /// @notice IMD available for refunds.
    function balance() public view returns (uint256) {
        return imd.balanceOf(address(this));
    }

    /// @notice Donate IMD to the fund. The caller must have approved this contract.
    function donate(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        totalDonated += amount;
        emit Donated(msg.sender, amount);
        imd.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Refund up to `amount` IMD to the vault. Pays what the fund holds and returns it.
    function refund(uint256 amount) external returns (uint256 paid) {
        if (msg.sender != vault) revert NotVault();
        uint256 held = balance();
        paid = amount < held ? amount : held;
        if (paid > 0) {
            totalRefunded += paid;
            imd.safeTransfer(vault, paid);
        }
        emit Refunded(amount, paid);
    }
}
