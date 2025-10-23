// contracts/AToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AToken - Interest-bearing token representing deposits
/// @notice ERC20 token that represents user's share in the lending pool
/// @dev Simple implementation: 1 aToken = 1 underlying * exchangeRate
contract AToken is ERC20, Ownable {
    address public immutable underlyingAsset;
    address public lendingPool;

    event Mint(address indexed user, uint256 amount);
    event Burn(address indexed user, uint256 amount);

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "Only lending pool");
        _;
    }

    constructor(string memory name, string memory symbol, address underlyingAsset_)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        require(underlyingAsset_ != address(0), "Invalid underlying asset");
        underlyingAsset = underlyingAsset_;
    }

    /// @notice Set lending pool address (only owner)
    function setLendingPool(address pool) external onlyOwner {
        lendingPool = pool;
    }

    /// @notice Mint aTokens to user (only lending pool)
    function mint(address to, uint256 amount) external onlyLendingPool {
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @notice Burn aTokens from user (only lending pool)
    function burn(address from, uint256 amount) external onlyLendingPool {
        _burn(from, amount);
        emit Burn(from, amount);
    }
}
