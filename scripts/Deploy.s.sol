//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/ERC20Mock.sol";
import "../contracts/MockOracle.sol";
import "../contracts/InterestRateModel.sol";
import "../contracts/AToken.sol";
import "../contracts/LendingPool.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy tokens
        ERC20Mock weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        ERC20Mock dai  = new ERC20Mock("Dai Stablecoin", "DAI", 18);
        ERC20Mock aWETH = new ERC20Mock("aWrapped Ether", "aWETH", 18);

        // Deploy Oracle
        MockOracle oracle = new MockOracle();

        // Deploy Interest Rate Model
        InterestRateModel rateModel = new InterestRateModel(
            0.02 ether, // base rate
            0.1 ether,  // slope1
            1 ether,    // slope2
            0.8 ether   // kink
        );

        // Deploy aToken
        AToken aToken = new AToken("aETH", "aETH", address(weth));

        // Deploy Lending Pool
        LendingPool pool = new LendingPool();

        // Setup pool
        pool.setOracle(address(oracle));
        pool.setInterestRateModel(address(rateModel));

        // **Make the pool owner of aToken**
        aToken.setLendingPool(address(pool));

        // Initialize WETH reserve
        pool.initReserve(
            address(weth),
            address(aToken),
            0.75 ether,  // 75% LTV
            0.8 ether,   // 80% liquidation threshold
            0.05 ether,  // 5% liquidation bonus
            0.5 ether    // 50% close factor
        );

        // Set prices
        oracle.setPrice(address(weth), 2000 ether);
        oracle.setPrice(address(dai), 1 ether);

        vm.stopBroadcast();
    }
}