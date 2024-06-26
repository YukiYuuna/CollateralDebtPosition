    // SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "./interfaces/ILiquidationCallback.sol";
import "../test/interfaces/IUniswapV3Factory.sol";
import "../test/interfaces/ISwapRouter.sol";
import "./kcCoin.sol";
import "./kcEngine.sol";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract LiquidationCallback is ILiquidationCallback {

    IUniswapV3Factory public constant uniswapV3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    ISwapRouter public constant uniswapV3Router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    kcCoin public immutable kcToken;
    address public immutable engine;
    address public immutable usdc;

    constructor (address coin, address _engine, address _usdc) payable {
        kcToken = kcCoin(coin);
        engine = _engine;
        usdc = _usdc;
    }

    function onCollateralReceived(address collateralToken, uint256 collateralAmount) external {
        kcToken.approve(address(uniswapV3Router), type(uint256).max);

        // trade collateral token to crab
        bytes memory path;
        if(address(collateralToken) == address(usdc)) {
            path = bytes.concat(
            bytes20(address(collateralToken)),
            bytes3(uint24(500)), // fee tier for the pool is 0.05%
            bytes20(address(kcToken))
            );
        }
        else {
            path = bytes.concat(
            bytes20(address(collateralToken)),
            bytes3(uint24(500)), // fee tier for the pool is 0.05%
            bytes20(address(usdc)),
            bytes3(uint24(500)),
            bytes20(address(kcToken))
            );
        }       

        //ratio needed to convert to 1e18
        uint256 difference = kcToken.decimals() - ERC20(collateralToken).decimals();
        uint256 ratio = difference == 0 ? 1 : 10 ** difference;

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp + 12 seconds,
            amountIn: collateralAmount,
            amountOutMinimum: collateralAmount * 99 / 100 * ratio // expect 99% of collateral amount but convert to 1e18
        });

        uint256 amountOut = uniswapV3Router.exactInput(params);
        kcToken.transferFrom(address(this), engine, amountOut);
    }
}