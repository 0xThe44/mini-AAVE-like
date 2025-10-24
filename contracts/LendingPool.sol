// contracts/LendingPool.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AToken} from "./AToken.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {MockOracle} from "./MockOracle.sol";

/// @title LendingPool - Minimal AAVE-like lending protocol
/// @notice Core lending functionality with deposit, borrow, repay, and liquidation
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MAX_HEALTH_FACTOR = type(uint256).max;

    // Reserve data structure
    struct ReserveData {
        uint256 totalLiquidity;
        uint256 totalBorrows;
        uint256 liquidityIndex;
        uint256 borrowIndex;
        uint256 ltv; // Loan-to-value ratio (e.g., 75% = 0.75 * 1e18)
        uint256 liquidationThreshold; // Liquidation threshold (e.g., 80% = 0.8 * 1e18)
        uint256 liquidationBonus; // Liquidation bonus (e.g., 5% = 0.05 * 1e18)
        uint256 closeFactor; // Max % of debt that can be repaid in one liquidation (e.g., 50% = 0.5 * 1e18)
        bool isActive;
        address aToken;
        uint256 lastUpdateTimestamp;
    }

    // User data structure
    struct UserData {
        uint256 collateral;
        // debt stored as "scaled debt": actualDebt = scaledDebt * reserve.borrowIndex / WAD
        uint256 scaledDebt;
        bool collateralEnabled;
    }

    // Storage
    mapping(address => ReserveData) public reserves;
    mapping(address => mapping(address => UserData)) public userData; // userData[user][asset]
    mapping(address => address[]) public userAssets; // Track user's assets
    mapping(address => mapping(address => bool)) public userAssetExists; // userAssetExists[user][asset]

    address public oracle;
    address public interestRateModel;

    // Events
    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, address indexed asset, uint256 amount);
    event Repay(address indexed user, address indexed asset, uint256 amount);
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        address indexed debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        uint256 collateralSeized
    );

    modifier onlyActiveReserve(address asset) {
        require(reserves[asset].isActive, "Reserve not active");
        _;
    }

    constructor() Ownable(msg.sender) {}

    /// @notice Initialize a reserve
    function initReserve(
        address asset,
        address aToken,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 closeFactor
    ) external onlyOwner {
        require(!reserves[asset].isActive, "Reserve already active");
        require(ltv <= liquidationThreshold, "LTV must be <= liquidation threshold");

        reserves[asset] = ReserveData({
            totalLiquidity: 0,
            totalBorrows: 0,
            liquidityIndex: WAD,
            borrowIndex: WAD,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            closeFactor: closeFactor,
            isActive: true,
            aToken: aToken,
            lastUpdateTimestamp: block.timestamp
        });

        // set lendingPool in aToken (owner of aToken must be this caller)
        //AToken(aToken).setLendingPool(address(this));

        emit /* optional */ Deposit(address(0), asset, 0); // (no-op event to signal init)
    }

    /// @notice Set oracle address
    function setOracle(address oracle_) external onlyOwner {
        require(oracle_ != address(0), "Oracle zero");
        oracle = oracle_;
    }

    /// @notice Set interest rate model
    function setInterestRateModel(address model) external onlyOwner {
        interestRateModel = model;
    }

    /// @notice Deposit assets to earn interest
    function deposit(address asset, uint256 amount) external nonReentrant onlyActiveReserve(asset) {
        require(amount > 0, "Amount must be positive");

        _accrueInterest(asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        ReserveData storage reserve = reserves[asset];
        reserve.totalLiquidity += amount;

        // Update user data
        if (!userAssetExists[msg.sender][asset]) {
            userAssets[msg.sender].push(asset);
            userAssetExists[msg.sender][asset] = true;
        }
        userData[msg.sender][asset].collateral += amount;
        userData[msg.sender][asset].collateralEnabled = true; // Auto-enable collateral

        // Mint aTokens in aToken units using liquidityIndex
        uint256 aTokenAmount = (amount * WAD) / reserve.liquidityIndex;
        require(aTokenAmount > 0, "aToken amount zero");
        AToken(reserve.aToken).mint(msg.sender, aTokenAmount);

        emit Deposit(msg.sender, asset, amount);
    }

    /// @notice Withdraw assets
    function withdraw(address asset, uint256 amount) external nonReentrant onlyActiveReserve(asset) {
        require(amount > 0, "Amount must be positive");
        require(userData[msg.sender][asset].collateral >= amount, "Insufficient collateral");

        _accrueInterest(asset);

        // Check health factor after withdrawal
        userData[msg.sender][asset].collateral -= amount;
        require(getHealthFactor(msg.sender) >= WAD, "Health factor too low");

        ReserveData storage reserve = reserves[asset];
        require(reserve.totalLiquidity >= amount, "Reserve liquidity insufficient");
        reserve.totalLiquidity -= amount;

        // Burn aTokens (convert underlying -> aToken units)
        uint256 aTokenAmount = (amount * WAD) / reserve.liquidityIndex;
        AToken(reserve.aToken).burn(msg.sender, aTokenAmount);

        IERC20(asset).safeTransfer(msg.sender, amount);

        // If both positions zero, clear existence flag (we keep asset in array for gas predictability)
        if (userData[msg.sender][asset].collateral == 0 && userData[msg.sender][asset].scaledDebt == 0) {
            userAssetExists[msg.sender][asset] = false;
        }

        emit Withdraw(msg.sender, asset, amount);
    }

    /// @notice Borrow assets
    function borrow(address asset, uint256 amount) external nonReentrant onlyActiveReserve(asset) {
        require(amount > 0, "Amount must be positive");
        require(reserves[asset].totalLiquidity >= amount, "Insufficient liquidity");
        require(oracle != address(0), "Oracle not set");
        require(interestRateModel != address(0), "Interest model not set");

        _accrueInterest(asset);

        // Check LTV before borrow
        uint256 totalCollateralValue = 0;
        uint256 totalDebtValue = 0;
        uint256 totalBorrowCapacity = 0;
        address[] memory assets = userAssets[msg.sender];

        for (uint256 i = 0; i < assets.length; i++) {
            address userAsset = assets[i];
            UserData memory ud = userData[msg.sender][userAsset];
            ReserveData memory r = reserves[userAsset];

            uint256 price = MockOracle(oracle).getPrice(userAsset);
            require(price > 0, "Price zero");
            if (ud.collateral > 0 && ud.collateralEnabled) {
                uint256 collValue = (ud.collateral * price) / WAD;
                totalCollateralValue += collValue;
                // capacity from this collateral = collValue * asset.ltv
                totalBorrowCapacity += (collValue * r.ltv) / WAD;
            }
            if (ud.scaledDebt > 0) {
                // compute actual debt using reserve.borrowIndex
                uint256 userDebt = (ud.scaledDebt * reserves[userAsset].borrowIndex) / WAD;
                uint256 debtVal = (userDebt * price) / WAD;
                totalDebtValue += debtVal;
            }
        }

        uint256 assetPrice = MockOracle(oracle).getPrice(asset);
        require(assetPrice > 0, "Price zero");
        uint256 newDebtValue = totalDebtValue + (amount * assetPrice) / WAD;
        require(newDebtValue <= totalBorrowCapacity, "Borrow exceeds aggregate LTV");

        // Add debt and check health factor
        if (!userAssetExists[msg.sender][asset]) {
            userAssets[msg.sender].push(asset);
            userAssetExists[msg.sender][asset] = true;
        }
        // store scaled debt: scaled = amount * WAD / borrowIndex
        ReserveData storage reserve = reserves[asset];
        uint256 scaled = (amount * WAD) / reserve.borrowIndex;
        userData[msg.sender][asset].scaledDebt += scaled;
        require(getHealthFactor(msg.sender) >= WAD, "Health factor too low");

        reserve.totalBorrows += amount;
        reserve.totalLiquidity -= amount;

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, asset, amount);
    }

    /// @notice Enable collateral for borrowing (simplified - auto-enable on deposit)
    function enableCollateral(address asset) external {
        require(reserves[asset].isActive, "Reserve not active");
        userData[msg.sender][asset].collateralEnabled = true;
    }

    /// @notice Repay debt
    function repay(address asset, uint256 amount) external nonReentrant onlyActiveReserve(asset) {
        require(amount > 0, "Amount must be positive");
        require(userData[msg.sender][asset].scaledDebt > 0, "No debt to repay");

        _accrueInterest(asset);

        ReserveData storage reserve = reserves[asset];
        // actual debt
        uint256 actualDebt = (userData[msg.sender][asset].scaledDebt * reserve.borrowIndex) / WAD;
        uint256 repayAmount = amount > actualDebt ? actualDebt : amount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);

        // reduce scaledDebt accordingly: scaledDelta = repayAmount * WAD / borrowIndex
        uint256 scaledDelta = (repayAmount * WAD) / reserve.borrowIndex;
        if (scaledDelta >= userData[msg.sender][asset].scaledDebt) {
            userData[msg.sender][asset].scaledDebt = 0;
        } else {
            userData[msg.sender][asset].scaledDebt -= scaledDelta;
        }

        reserve.totalBorrows -= repayAmount;
        reserve.totalLiquidity += repayAmount;

        emit Repay(msg.sender, asset, repayAmount);
    }

    /// @notice Liquidate undercollateralized position
    function liquidate(address borrower, address debtAsset, address collateralAsset, uint256 repayAmount)
        external
        nonReentrant
    {
        require(borrower != msg.sender, "Cannot liquidate self");
        require(getHealthFactor(borrower) < WAD, "Borrower not liquidatable");
        require(oracle != address(0), "Oracle not set");

        _accrueInterest(debtAsset);
        _accrueInterest(collateralAsset);

        ReserveData storage debtReserve = reserves[debtAsset];
        uint256 borrowerDebt = (userData[borrower][debtAsset].scaledDebt * debtReserve.borrowIndex) / WAD;
        uint256 maxRepay = (borrowerDebt * debtReserve.closeFactor) / WAD;
        uint256 actualRepay = repayAmount > maxRepay ? maxRepay : repayAmount;
        if (actualRepay > borrowerDebt) actualRepay = borrowerDebt;

        // Calculate collateral to seize (include bonus)
        uint256 debtPrice = MockOracle(oracle).getPrice(debtAsset);
        uint256 collateralPrice = MockOracle(oracle).getPrice(collateralAsset);
        require(debtPrice > 0 && collateralPrice > 0, "Price zero");
        uint256 collateralToSeize =
            (actualRepay * debtPrice * (WAD + reserves[collateralAsset].liquidationBonus)) / (collateralPrice * WAD);

        require(collateralToSeize <= userData[borrower][collateralAsset].collateral, "Insufficient collateral");

        // Transfer debt asset from liquidator
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), actualRepay);

        // Update borrower's scaled debt
        uint256 scaledDelta = (actualRepay * WAD) / debtReserve.borrowIndex;
        if (scaledDelta >= userData[borrower][debtAsset].scaledDebt) {
            userData[borrower][debtAsset].scaledDebt = 0;
        } else {
            userData[borrower][debtAsset].scaledDebt -= scaledDelta;
        }
        userData[borrower][collateralAsset].collateral -= collateralToSeize;

        // Update reserves
        debtReserve.totalBorrows -= actualRepay;
        debtReserve.totalLiquidity += actualRepay;

        // Decrease liquidity for collateral and burn aToken of borrower (convert underlying -> aToken units)
        ReserveData storage collateralReserve = reserves[collateralAsset];
        collateralReserve.totalLiquidity -= collateralToSeize;
        uint256 aTokenAmount = (collateralToSeize * WAD) / collateralReserve.liquidityIndex;
        AToken(collateralReserve.aToken).burn(borrower, aTokenAmount);

        // Transfer collateral to liquidator
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidation(msg.sender, borrower, debtAsset, collateralAsset, actualRepay, collateralToSeize);
    }

    /// @notice Get user account data
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        require(oracle != address(0), "Oracle not set");
        address[] memory assets = userAssets[user];
        uint256 weightedLiquidationSum = 0;
        uint256 totalBorrowCapacity = 0;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            UserData memory userData_ = userData[user][asset];
            ReserveData memory reserve = reserves[asset];

            if (userData_.collateral > 0 && userData_.collateralEnabled) {
                uint256 assetPrice = MockOracle(oracle).getPrice(asset);
                if (assetPrice == 0) continue;
                uint256 collateralValue = (userData_.collateral * assetPrice) / WAD;
                totalCollateralETH += collateralValue;
                // accumulate weighted liquidation threshold (collateralValue * threshold)
                weightedLiquidationSum += (collateralValue * reserve.liquidationThreshold) / WAD;
                // accumulate borrow capacity (collateralValue * ltv)
                totalBorrowCapacity += (collateralValue * reserve.ltv) / WAD;
            }

            if (userData_.scaledDebt > 0) {
                uint256 assetPrice = MockOracle(oracle).getPrice(asset);
                if (assetPrice == 0) continue;
                uint256 actualDebt = (userData_.scaledDebt * reserve.borrowIndex) / WAD;
                uint256 debtValue = (actualDebt * assetPrice) / WAD;
                totalDebtETH += debtValue;
            }
        }

        // currentLiquidationThreshold — взвешенный по стоимости коллатерали
        currentLiquidationThreshold = totalCollateralETH > 0 ? (weightedLiquidationSum * WAD) / totalCollateralETH : 0;
        // available borrows рассчитываем через LTV (capacity) а не через liquidationThreshold
        availableBorrowsETH = totalBorrowCapacity > totalDebtETH ? totalBorrowCapacity - totalDebtETH : 0;
        ltv = totalCollateralETH > 0 ? (totalDebtETH * WAD) / totalCollateralETH : 0;
        healthFactor =
            totalDebtETH == 0 ? MAX_HEALTH_FACTOR : (totalCollateralETH * currentLiquidationThreshold) / totalDebtETH;
    }

    /// @notice Get health factor for user
    function getHealthFactor(address user) public view returns (uint256) {
        (,,,,, uint256 healthFactor) = this.getUserAccountData(user);
        return healthFactor;
    }

    /// @notice Accrue interest for a reserve
    function _accrueInterest(address asset) internal {
        ReserveData storage reserve = reserves[asset];
        uint256 timeDelta = block.timestamp - reserve.lastUpdateTimestamp;

        if (timeDelta == 0) return;
        if (interestRateModel == address(0)) {
            reserve.lastUpdateTimestamp = block.timestamp;
            return;
        }

        uint256 borrowRate =
            InterestRateModel(interestRateModel).getBorrowRate(reserve.totalBorrows, reserve.totalLiquidity);

        // multiplier = borrowRate * timeDelta / year (in WAD)
        uint256 rateTimesDelta = (borrowRate * timeDelta) / SECONDS_PER_YEAR; // still WAD
        // interest accrued on borrows: reserve.totalBorrows * rateTimesDelta / WAD
        uint256 interestAccrued = (reserve.totalBorrows * rateTimesDelta) / WAD;

        // update indices: newIndex = oldIndex * (1 + rateTimesDelta/WAD)
        // borrowIndex
        if (reserve.borrowIndex > 0) {
            uint256 borrowIndexIncrease = (reserve.borrowIndex * rateTimesDelta) / WAD;
            reserve.borrowIndex += borrowIndexIncrease;
        }
        // liquidityIndex: suppliers earn same interest as borrows in this simplified model
        if (reserve.liquidityIndex > 0) {
            uint256 liquidityIndexIncrease = (reserve.liquidityIndex * rateTimesDelta) / WAD;
            reserve.liquidityIndex += liquidityIndexIncrease;
        }

        if (interestAccrued > 0) {
            reserve.totalBorrows += interestAccrued;
            reserve.totalLiquidity += interestAccrued;
        }

        reserve.lastUpdateTimestamp = block.timestamp;
    }
}
