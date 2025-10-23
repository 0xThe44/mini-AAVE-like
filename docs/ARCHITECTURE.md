# Architecture Documentation

## Protocol Flow

### Deposit Flow
```
User → LendingPool.deposit() → Transfer Asset → Mint AToken → Update Reserves
```

### Borrow Flow
```
User → LendingPool.borrow() → Check Health Factor → Transfer Asset → Update Debt
```

### Liquidation Flow
```
Liquidator → LendingPool.liquidate() → Check Health Factor → Transfer Debt Asset → Seize Collateral
```

## Data Structures

### ReserveData
```solidity
struct ReserveData {
    uint256 totalLiquidity;        // Total liquidity in pool
    uint256 totalBorrows;          // Total borrowed amount
    uint256 liquidityIndex;        // Interest accrual index
    uint256 borrowIndex;           // Borrow interest index
    uint256 ltv;                   // Loan-to-value ratio
    uint256 liquidationThreshold;  // Liquidation threshold
    uint256 liquidationBonus;     // Liquidation bonus
    uint256 closeFactor;           // Max % of debt repayable
    bool isActive;                 // Reserve status
    address aToken;               // Associated aToken
    uint256 lastUpdateTimestamp;  // Last interest accrual
}
```

### UserData
```solidity
struct UserData {
    uint256 collateral;           // User's collateral amount
    uint256 debt;                 // User's debt amount
    bool collateralEnabled;       // Collateral enabled status
}
```

## Interest Rate Model

### Piecewise Linear Formula

```
BorrowRate = baseRate + (U <= kink ? U*slope1 : kink*slope1 + (U-kink)*slope2)
```

### Parameters
- **baseRate**: 2% APR (0.02 * 1e18)
- **slope1**: 10% APR (0.10 * 1e18) - below kink
- **slope2**: 100% APR (1.0 * 1e18) - above kink
- **kink**: 80% utilization (0.8 * 1e18)

### Example Calculation
```
Utilization = 60%
BorrowRate = 0.02 + (0.6 * 0.10) = 0.08 = 8% APR

Utilization = 90%
BorrowRate = 0.02 + (0.8 * 0.10) + ((0.9 - 0.8) * 1.0) = 0.12 = 12% APR
```

## Health Factor Calculation

### Formula
```
HealthFactor = (totalCollateral * liquidationThreshold) / totalDebt
```

### Example
```
Collateral: 100 ETH @ $2000 = $200,000
Debt: $150,000
Liquidation Threshold: 80%

HealthFactor = ($200,000 * 0.8) / $150,000 = 1.067
```

## Liquidation Mechanics

### Close Factor
- Maximum 50% of debt can be repaid in one liquidation
- Prevents complete liquidation in single transaction

### Liquidation Bonus
- 5% bonus for liquidators
- Incentivizes liquidation of bad debt

### Collateral Calculation
```
collateralToSeize = repayAmount * (1 + liquidationBonus) * debtPrice / collateralPrice
```

### Example
```
Repay: $10,000 DAI
Debt Price: $1 per DAI
Collateral Price: $2000 per ETH
Liquidation Bonus: 5%

collateralToSeize = $10,000 * 1.05 * $1 / $2000 = 5.25 ETH
```

## Security Considerations

### Reentrancy Protection
- All external calls protected with `nonReentrant`
- Checks-Effects-Interactions pattern

### Access Control
- Owner-only admin functions
- Minimal privileged operations

### Input Validation
- Positive amount checks
- Active reserve validation
- Health factor validation

### Oracle Security
- Price validation (non-zero)
- Staleness checks (in production)
- Multiple price sources (recommended)

## Gas Optimization

### Storage Layout
- Struct packing for efficiency
- Minimal storage operations
- Batch operations where possible

### Assembly Usage
- Gas-optimized calculations
- Overflow protection
- Efficient arithmetic

## Upgrade Considerations

### Proxy Pattern
- Upgradeable implementation
- Storage layout compatibility
- Function selector conflicts

### Governance
- Timelock for admin functions
- Community voting
- Emergency procedures

## Monitoring and Events

### Critical Events
- `Deposit`: Asset deposits
- `Withdraw`: Asset withdrawals
- `Borrow`: Debt creation
- `Repay`: Debt repayment
- `Liquidation`: Position liquidation

### Monitoring Metrics
- Total liquidity per asset
- Total borrows per asset
- Health factor distribution
- Interest rate changes
- Liquidation events
