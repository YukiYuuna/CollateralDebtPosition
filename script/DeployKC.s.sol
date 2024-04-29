// SPDX-License-Identifier: MIT

import {Script} from 'forge-std/Script.sol';
import {kcCoin} from '../src/kcCoin.sol';
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

    function run() external returns(kcCoin, kcEngine, HelperConfig) {
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
        kcCoin kc = new kcCoin();
        kcEngine engine = new kcEngine(tokenAddresses, priceFeedAddresses, priceFeedDecimals, tvlRatios, address(kcStableCoin));
        vm.stopBroadcast();

        return (kc, engine, helperConfig);
    }
}