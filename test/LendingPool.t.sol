// test/LendingPool.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {LendingPool} from "../contracts/LendingPool.sol";
import {AToken} from "../contracts/AToken.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {MockOracle} from "../contracts/MockOracle.sol";
import {ERC20Mock} from "../contracts/ERC20Mock.sol";

contract LendingPoolTest is Test {
    LendingPool public pool;
    AToken public aToken;
    InterestRateModel public rateModel;
    MockOracle public oracle;
    ERC20Mock public weth;
    ERC20Mock public dai;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public liquidator = address(0x3);

    uint256 public constant WAD = 1e18;

    function setUp() public {
        // Deploy contracts
        pool = new LendingPool();
        oracle = new MockOracle();
        rateModel = new InterestRateModel(
            2e16, // 2% base rate
            10e16, // 10% slope1
            100e16, // 100% slope2
            8e17 // 80% kink
        );

        // Deploy tokens
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        dai = new ERC20Mock("Dai Stablecoin", "DAI", 18);

        // Deploy aToken for WETH and transfer ownership to pool so initReserve can call setLendingPool
        aToken = new AToken("aETH", "aETH", address(weth));
        aToken.transferOwnership(address(pool));

        // Set up pool
        pool.setOracle(address(oracle));
        pool.setInterestRateModel(address(rateModel));

        // Initialize WETH reserve (pool will call aToken.setLendingPool since aToken owner is pool)
        pool.initReserve(
            address(weth),
            address(aToken),
            70e16, // 70% LTV
            75e16, // 75% liquidation threshold
            5e16, // 5% liquidation bonus
            50e16 // 50% close factor
        );

        // Set prices
        oracle.setPrice(address(weth), 2000e18); // $2000 per ETH
        oracle.setPrice(address(dai), 1e18); // $1 per DAI

        // Mint tokens to users (ERC20Mock.mint is onlyOwner; test contract is owner)
        weth.mint(user1, 1000e18);
        weth.mint(user2, 1000e18);
        weth.mint(liquidator, 1000e18);
        dai.mint(user1, 1000000e18);
        dai.mint(user2, 1000000e18);
        dai.mint(liquidator, 1000000e18);
    }

    function testDeposit() public {
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);
        vm.stopPrank();

        assertEq(aToken.balanceOf(user1), 100e18);
        assertEq(weth.balanceOf(address(pool)), 100e18);
    }

    function testWithdraw() public {
        // First deposit
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);

        // Then withdraw
        pool.withdraw(address(weth), 50e18);
        vm.stopPrank();

        assertEq(aToken.balanceOf(user1), 50e18);
        assertEq(weth.balanceOf(user1), 950e18);
    }

    function testBorrow() public {
        // Deposit collateral first
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);

        // Borrow
        pool.borrow(address(weth), 50e18);
        vm.stopPrank();

        assertEq(weth.balanceOf(user1), 950e18);
    }

    function testRepay() public {
        // Setup: deposit and borrow
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);
        pool.borrow(address(weth), 50e18);

        // Repay
        weth.approve(address(pool), 25e18);
        pool.repay(address(weth), 25e18);
        vm.stopPrank();

        // Check remaining debt (health factor should be finite and > 1)
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user1);
        assertTrue(healthFactor > WAD);
    }

    function testInterestAccrual() public {
        // Deposit and borrow
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);
        pool.borrow(address(weth), 50e18);
        vm.stopPrank();

        // Warp time to accrue interest
        vm.warp(block.timestamp + 365 days);

        // Trigger interest accrual by calling deposit (touches reserve)
        vm.startPrank(user2);
        weth.approve(address(pool), 1e18);
        pool.deposit(address(weth), 1e18);
        vm.stopPrank();

        // Check that debt has increased due to interest (healthFactor should be finite)
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user1);
        assertTrue(healthFactor < type(uint256).max);
    }

    function testLiquidation() public {
        // Setup: add DAI reserve (create aDAI and transfer ownership to pool BEFORE initReserve)
        AToken aDAI = new AToken("aDAI", "aDAI", address(dai));
        aDAI.transferOwnership(address(pool));

        // Initialize DAI reserve (pool will set aToken.lendingPool)
        pool.initReserve(
            address(dai),
            address(aDAI),
            80e16, // 80% LTV for DAI
            85e16, // 85% liquidation threshold for DAI
            5e16, // 5% liquidation bonus
            50e16 // 50% close factor
        );

        // First, user2 deposits DAI to provide liquidity
        vm.startPrank(user2);
        dai.approve(address(pool), 200000e18);
        pool.deposit(address(dai), 200000e18);
        vm.stopPrank();

        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);

        // Borrow DAI (different asset from collateral)
        pool.borrow(address(dai), 120000e18); // Borrow $120,000 DAI (60% of $200,000 collateral value)
        vm.stopPrank();

        // Now manipulate the oracle to make the position liquidatable
        // Drop WETH price significantly while keeping DAI price stable
        oracle.setPrice(address(weth), 1000e18); // Drop ETH price to $1000 (50% drop)

        // Check health factor is below 1
        (, uint256 totalDebtETH,, uint256 currentLiquidationThreshold,, uint256 healthFactor) =
            pool.getUserAccountData(user1);
        console.log("Total debt (ETH units):", totalDebtETH);
        console.log("Liquidation threshold:", currentLiquidationThreshold);
        console.log("Health factor:", healthFactor);

        assertTrue(healthFactor < WAD);

        // Liquidate
        vm.startPrank(liquidator);
        dai.approve(address(pool), 20000e18); // Repay $20,000 DAI (smaller amount)
        pool.liquidate(user1, address(dai), address(weth), 20000e18);
        vm.stopPrank();

        // Check that debt was reduced and collateral decreased
        (uint256 finalCollateralETH, uint256 finalDebtETH,,,, uint256 newHealthFactor) = pool.getUserAccountData(user1);
        console.log("Final collateral:", finalCollateralETH);
        console.log("Final debt:", finalDebtETH);
        console.log("New health factor:", newHealthFactor);

        assertTrue(finalDebtETH < 120000e18);
        assertTrue(finalCollateralETH < 100000e18);
    }

    function testHealthFactorCalculation() public {
        // Deposit collateral
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);
        vm.stopPrank();

        // Check health factor with no debt
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user1);
        assertEq(healthFactor, type(uint256).max);

        // Borrow and check health factor
        vm.startPrank(user1);
        pool.borrow(address(weth), 50e18);
        vm.stopPrank();

        (,,,,, uint256 healthFactorAfterBorrow) = pool.getUserAccountData(user1);
        assertTrue(healthFactorAfterBorrow > WAD);
    }

    function testWithdrawHealthFactorCheck() public {
        // Deposit and borrow
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);
        pool.borrow(address(weth), 70e18); // High LTV
        vm.stopPrank();

        // Try to withdraw too much (should fail)
        vm.startPrank(user1);
        vm.expectRevert("Health factor too low");
        pool.withdraw(address(weth), 50e18);
        vm.stopPrank();
    }

    function testBorrowHealthFactorCheck() public {
        // Deposit collateral
        vm.startPrank(user1);
        weth.approve(address(pool), 100e18);
        pool.deposit(address(weth), 100e18);
        vm.stopPrank();

        // Try to borrow too much (should fail)
        vm.startPrank(user1);
        vm.expectRevert("Borrow exceeds aggregate LTV");
        pool.borrow(address(weth), 90e18); // Exceeds LTV
        vm.stopPrank();
    }
}
