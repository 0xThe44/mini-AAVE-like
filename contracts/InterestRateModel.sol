// contracts/InterestRateModel.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title InterestRateModel - Piecewise linear interest rate model
/// @notice Calculates borrow rates based on utilization
/// @dev Formula: BorrowRate = baseRate + (U <= kink ? U*slope1 : kink*slope1 + (U-kink)*slope2)
contract InterestRateModel {
    uint256 public constant WAD = 1e18;

    // Rate parameters
    uint256 public immutable baseRate; // 2% APR = 0.02 * 1e18
    uint256 public immutable slope1; // 10% APR = 0.10 * 1e18
    uint256 public immutable slope2; // 100% APR = 1.0 * 1e18
    uint256 public immutable kink; // 80% = 0.8 * 1e18

    constructor(uint256 baseRate_, uint256 slope1_, uint256 slope2_, uint256 kink_) {
        baseRate = baseRate_;
        slope1 = slope1_;
        slope2 = slope2_;
        kink = kink_;
    }

    /// @notice Calculate borrow rate based on utilization
    /// @param totalBorrows Total amount borrowed
    /// @param totalLiquidity Total liquidity available
    /// @return borrowRate Annual borrow rate in WAD (1e18)
    function getBorrowRate(uint256 totalBorrows, uint256 totalLiquidity) external view returns (uint256 borrowRate) {
        if (totalLiquidity == 0) return baseRate;

        // Calculate utilization: U = totalBorrows / totalLiquidity
        uint256 utilization = (totalBorrows * WAD) / totalLiquidity;

        if (utilization <= kink) {
            // Below kink: linear increase
            borrowRate = baseRate + (utilization * slope1) / WAD;
        } else {
            // Above kink: steeper increase
            borrowRate = baseRate + (kink * slope1) / WAD + ((utilization - kink) * slope2) / WAD;
        }
    }
}
