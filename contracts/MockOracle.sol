// contracts/MockOracle.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockOracle - Simple price oracle for testing
/// @notice Returns fixed prices for testing purposes
/// @dev In production, use Chainlink or other reliable oracle
contract MockOracle is Ownable {
    mapping(address => uint256) public prices;

    event PriceSet(address indexed asset, uint256 price);

    constructor() Ownable(msg.sender) {}

    /// @notice Set price for an asset (only owner)
    /// @param asset Asset address
    /// @param price Price in ETH (18 decimals)
    function setPrice(address asset, uint256 price) external onlyOwner {
        require(price > 0, "Invalid price");
        prices[asset] = price;
        emit PriceSet(asset, price);
    }

    /// @notice Get price of an asset
    /// @param asset Asset address
    /// @return price Price in ETH (18 decimals)
    function getPrice(address asset) external view returns (uint256 price) {
        price = prices[asset];
        require(price > 0, "Asset not supported");
    }
}
