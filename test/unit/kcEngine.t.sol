//SPDX-License-Identifier: MIT

pragma solidity 0.8.21;
import {Test, console} from 'forge-std/Test.sol';
import {DeployKC} from '../../script/DeployKC.s.sol';
import {kcCoin} from '../../src/kcCoin.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {kcEngine} from '../../src/kcEngine.sol';

contract kcEngineTest is Test {
    error kcEngine__testMismatchingUsdConvertor();
    
    DeployKC deployer;
    HelperConfig config;
    kcCoin kc;
    kcEngine engine;
    address weth;
    address wethUsdPriceFeed;
    address usdc;
    address usdcUsdPriceFeed;

    address public user = address(1);
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployKC();
        (kc, engine, config) = deployer.run();
        (wethUsdPriceFeed, weth,,,,,) = config.activeNetworkConfig();
        vm.deal(user, STARTING_USER_BALANCE);
    }

    ///////////////
    //Price tests//
    ///////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        vm.startPrank(user);
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getPriceInUSDForTokens(weth, ethAmount);
        console.log('expect usd',expectedUsd);
        console.log('actual usd',actualUsd);
        if(actualUsd != expectedUsd) {
            revert kcEngine__testMismatchingUsdConvertor();
        }
    }
}