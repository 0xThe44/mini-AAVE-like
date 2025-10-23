// scripts/deploy.js
const { ethers } = require("hardhat");

async function main() {
    console.log("Deploying Mini-Aave Protocol...");
    
    // Deploy ERC20 tokens
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const weth = await ERC20Mock.deploy("Wrapped Ether", "WETH", 18);
    const dai = await ERC20Mock.deploy("Dai Stablecoin", "DAI", 18);
    
    console.log("WETH deployed to:", weth.address);
    console.log("DAI deployed to:", dai.address);
    
    // Deploy Oracle
    const MockOracle = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracle.deploy();
    
    console.log("Oracle deployed to:", oracle.address);
    
    // Deploy Interest Rate Model
    const InterestRateModel = await ethers.getContractFactory("InterestRateModel");
    const rateModel = await InterestRateModel.deploy(
        ethers.utils.parseEther("0.02"),  // 2% base rate
        ethers.utils.parseEther("0.10"),  // 10% slope1
        ethers.utils.parseEther("1.0"),   // 100% slope2
        ethers.utils.parseEther("0.8")    // 80% kink
    );
    
    console.log("Interest Rate Model deployed to:", rateModel.address);
    
    // Deploy AToken
    const AToken = await ethers.getContractFactory("AToken");
    const aToken = await AToken.deploy("aETH", "aETH", weth.address);
    
    console.log("AToken deployed to:", aToken.address);
    
    // Deploy Lending Pool
    const LendingPool = await ethers.getContractFactory("LendingPool");
    const pool = await LendingPool.deploy();
    
    console.log("Lending Pool deployed to:", pool.address);
    
    // Setup
    await pool.setOracle(oracle.address);
    await pool.setInterestRateModel(rateModel.address);
    await aToken.setLendingPool(pool.address);
    
    // Initialize WETH reserve
    await pool.initReserve(
        weth.address,
        aToken.address,
        ethers.utils.parseEther("0.75"),  // 75% LTV
        ethers.utils.parseEther("0.80"),  // 80% liquidation threshold
        ethers.utils.parseEther("0.05"),  // 5% liquidation bonus
        ethers.utils.parseEther("0.50")   // 50% close factor
    );
    
    // Set prices
    await oracle.setPrice(weth.address, ethers.utils.parseEther("2000")); // $2000 per ETH
    await oracle.setPrice(dai.address, ethers.utils.parseEther("1"));     // $1 per DAI
    
    console.log("Setup complete!");
    console.log("WETH address:", weth.address);
    console.log("DAI address:", dai.address);
    console.log("Pool address:", pool.address);
    console.log("AToken address:", aToken.address);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
