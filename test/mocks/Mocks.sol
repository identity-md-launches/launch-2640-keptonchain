// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stands in for IMD and for any plain ERC-20 a team might lock. Mintable by anyone, tests only.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A token that takes 1% on every transfer: what the vault must refuse.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice A plain ERC-20 with a `burn` that lies: it succeeds without burning anything.
contract FakeBurnToken is ERC20 {
    constructor() ERC20("Fake", "FAKE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256) external pure {}
}

/// @notice A token whose `burn` removes only half of what it is asked to.
contract HalfBurnToken is ERC20 {
    constructor() ERC20("Half", "HALF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount / 2);
    }
}

/// @notice A fund that names the vault and its IMD but lies about refunds: `refund` returns a number
/// without paying, or reverts.
contract LyingFund {
    address public immutable imd;
    address public immutable vault;
    bool public immutable reverts;

    constructor(address imd_, address vault_, bool reverts_) {
        imd = imd_;
        vault = vault_;
        reverts = reverts_;
    }

    function refund(uint256 amount) external view returns (uint256) {
        require(!reverts, "refund failed");
        return amount * 100;
    }
}
