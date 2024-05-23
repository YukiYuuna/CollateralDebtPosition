// SPDX-License-Identifier: MIT

import {Script} from 'forge-std/Script.sol';
import {kcCoin} from '../src/kcCoin.sol';
import { kcGovernance } from '../src/kcGovernanceCoin.sol';
import {kcEngine} from '../src/kcEngine.sol';
import { HelperConfig } from "./HelperConfig.s.sol";
pragma solidity ^0.8.21;

contract DeployKC is Script {

    address[] tokenAddresses;
    address[] priceFeedAddresses;
    uint8[] priceFeedDecimals;
    uint8[] tvlRatios;

    // moved outside of run due to stackTooDeep exception caused by num of local vars
    kcCoin kcStableCoin;
    kcEngine engine;
    kcGovernance governance;

    function run() external returns(kcCoin, kcEngine, HelperConfig, kcGovernance) {
            HelperConfig helperConfig = new HelperConfig();
        (
            address wethUsdPriceFeed,
            address weth,
            address usdcUsdPriceFeed,
            address usdc,
            address solUsdPriceFeed,
            address sol,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        tokenAddresses = [weth, usdc, sol];
        priceFeedAddresses = [wethUsdPriceFeed, usdcUsdPriceFeed, solUsdPriceFeed];
        priceFeedDecimals = [18, 8, 8];
        tvlRatios = [70, 80, 50];

        vm.startBroadcast();
    
        kcStableCoin = new kcCoin();
        address alice = makeAddr("alice");
        engine = new kcEngine(tokenAddresses, priceFeedAddresses, priceFeedDecimals, tvlRatios, address(kcStableCoin));
        kcStableCoin.transferOwnership(address(engine));
        engine.transferOwnership(alice);
        governance = new kcGovernance(address(engine));

        vm.stopBroadcast();

        return (kcStableCoin, engine, helperConfig, governance);
    }
}