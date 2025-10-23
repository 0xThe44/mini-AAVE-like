# Demo Guide

## Quick Start

### 1. Setup Environment
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone repository
git clone <repo>
cd mini-aave

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
```

### 2. Build and Test
```bash
# Build contracts
forge build

# Run tests
forge test

# Run with gas report
forge test --gas-report
```

### 3. Local Deployment
```bash
# Start local node
anvil

# Deploy contracts (in another terminal)
forge script scripts/deploy.js --rpc-url http://127.0.0.1:8545 --broadcast
```

## Demo Scenarios

### Scenario 1: Basic Deposit and Withdraw

```bash
# 1. Deploy contracts
forge script scripts/deploy.js --rpc-url http://127.0.0.1:8545 --broadcast

# 2. Get contract addresses from deployment output
# 3. Interact with contracts using cast

# Deposit 100 WETH
cast send <POOL_ADDRESS> "deposit(address,uint256)" <WETH_ADDRESS> 100000000000000000000 --private-key <PRIVATE_KEY> --rpc-url http://127.0.0.1:8545

# Check aToken balance
cast call <ATOKEN_ADDRESS> "balanceOf(address)" <USER_ADDRESS> --rpc-url http://127.0.0.1:8545

# Withdraw 50 WETH
cast send <POOL_ADDRESS> "withdraw(address,uint256)" <WETH_ADDRESS> 50000000000000000000 --private-key <PRIVATE_KEY> --rpc-url http://127.0.0.1:8545
```

### Scenario 2: Borrow Against Collateral

```bash
# 1. Deposit collateral first
cast send <POOL_ADDRESS> "deposit(address,uint256)" <WETH_ADDRESS> 100000000000000000000 --private-key <PRIVATE_KEY> --rpc-url http://127.0.0.1:8545

# 2. Borrow 50 WETH
cast send <POOL_ADDRESS> "borrow(address,uint256)" <WETH_ADDRESS> 50000000000000000000 --private-key <PRIVATE_KEY> --rpc-url http://127.0.0.1:8545

# 3. Check health factor
cast call <POOL_ADDRESS> "getHealthFactor(address)" <USER_ADDRESS> --rpc-url http://127.0.0.1:8545
```

### Scenario 3: Liquidation

```bash
# 1. Setup: Deposit and borrow
cast send <POOL_ADDRESS> "deposit(address,uint256)" <WETH_ADDRESS> 100000000000000000000 --private-key <PRIVATE_KEY> --rpc-url http://127.0.0.1:8545
cast send <POOL_ADDRESS> "borrow(address,uint256)" <WETH_ADDRESS> 80000000000000000000 --private-key <PRIVATE_KEY> --rpc-url http://127.0.0.1:8545

# 2. Manipulate oracle price (drop ETH price by 50%)
cast send <ORACLE_ADDRESS> "setPrice(address,uint256)" <WETH_ADDRESS> 1000000000000000000000 --private-key <ADMIN_PRIVATE_KEY> --rpc-url http://127.0.0.1:8545

# 3. Check health factor (should be < 1.0)
cast call <POOL_ADDRESS> "getHealthFactor(address)" <USER_ADDRESS> --rpc-url http://127.0.0.1:8545

# 4. Liquidate position
cast send <POOL_ADDRESS> "liquidate(address,address,address,uint256)" <BORROWER_ADDRESS> <WETH_ADDRESS> <WETH_ADDRESS> 40000000000000000000 --private-key <LIQUIDATOR_PRIVATE_KEY> --rpc-url http://127.0.0.1:8545
```

## Test Commands

### Run Specific Tests
```bash
# Test deposit functionality
forge test --match-test testDeposit

# Test liquidation
forge test --match-test testLiquidation

# Test health factor
forge test --match-test testHealthFactor
```

### Fuzz Testing
```bash
# Run fuzz tests
forge test --fuzz-runs 1000

# Run invariant tests
forge test --invariant-runs 1000
```

### Gas Analysis
```bash
# Gas report
forge test --gas-report

# Gas snapshot
forge snapshot
```

## Monitoring

### Check Pool State
```bash
# Get total liquidity
cast call <POOL_ADDRESS> "reserves(address)" <WETH_ADDRESS> --rpc-url http://127.0.0.1:8545

# Get user account data
cast call <POOL_ADDRESS> "getUserAccountData(address)" <USER_ADDRESS> --rpc-url http://127.0.0.1:8545
```

### Monitor Events
```bash
# Watch for deposit events
cast logs --address <POOL_ADDRESS> --from-block latest

# Watch for liquidation events
cast logs --address <POOL_ADDRESS> --topic 0x<LIQUIDATION_EVENT_TOPIC> --from-block latest
```

## Troubleshooting

### Common Issues

1. **"Insufficient balance"**
   - Check token balances
   - Ensure proper approvals

2. **"Health factor too low"**
   - Deposit more collateral
   - Repay some debt
   - Check oracle prices

3. **"Reserve not active"**
   - Initialize reserve first
   - Check reserve parameters

4. **"Not liquidatable"**
   - Check health factor
   - Verify oracle prices
   - Ensure sufficient collateral

### Debug Commands
```bash
# Check token balance
cast call <TOKEN_ADDRESS> "balanceOf(address)" <USER_ADDRESS> --rpc-url http://127.0.0.1:8545

# Check allowance
cast call <TOKEN_ADDRESS> "allowance(address,address)" <USER_ADDRESS> <POOL_ADDRESS> --rpc-url http://127.0.0.1:8545

# Check oracle price
cast call <ORACLE_ADDRESS> "getPrice(address)" <TOKEN_ADDRESS> --rpc-url http://127.0.0.1:8545
```

## Advanced Scenarios

### Interest Accrual
```bash
# 1. Deposit and borrow
# 2. Warp time forward
cast rpc anvil_evm_increaseTime 31536000 --rpc-url http://127.0.0.1:8545

# 3. Trigger interest accrual
cast send <POOL_ADDRESS> "deposit(address,uint256)" <WETH_ADDRESS> 1000000000000000000 --private-key <PRIVATE_KEY> --rpc-url http://127.0.0.1:8545

# 4. Check increased debt
cast call <POOL_ADDRESS> "getUserAccountData(address)" <USER_ADDRESS> --rpc-url http://127.0.0.1:8545
```

### Multiple Users
```bash
# Setup multiple users with different private keys
# Test interactions between users
# Verify isolation of user data
```

### Stress Testing
```bash
# Large amounts
# Multiple operations
# Edge cases
# Gas limit testing
```
