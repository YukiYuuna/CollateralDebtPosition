//SPDX-License-Identifier: MIT

pragma solidity 0.8.21;
import {Test, console} from 'forge-std/Test.sol';
import {DeployKC} from '../../script/DeployKC.s.sol';
import {kcCoin} from '../../src/kcCoin.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {kcEngine} from '../../src/kcEngine.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {kcGovernance} from '../../src/kcGovernanceCoin.sol';

contract kcEngineTest is Test {
    error kcEngine__testMismatchingUsdConvertor();
    
    DeployKC deployer;
    HelperConfig helperConfig;
    kcCoin kc;
    kcEngine engine;
    kcGovernance governance;

    address weth;
    address wethUsdPriceFeed;
    address usdc;
    address usdcUsdPriceFeed;

    address public user = address(1);
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 amountOfWethCollateral = 15 ether;

    function setUp() public {
        deployer = new DeployKC();
        (kc, engine, helperConfig, governance) = deployer.run();
        (wethUsdPriceFeed, weth,,,,,) = helperConfig.activeNetworkConfig();
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
        assertEq(expectedUsd, actualUsd);
    }

    function testRepay() public {
        MockERC20(weth).mint(user, STARTING_USER_BALANCE);

        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);

        engine.depositCollateral(weth, STARTING_USER_BALANCE);
        uint256 deposited = engine.balanceOf(user);

        engine.withdrawCollateral(weth, STARTING_USER_BALANCE);
        uint256 endingBalance = engine.balanceOf(user);
        console.log('===>',endingBalance);
        console.log('===>',deposited);
    }

    function testDepositCollateral() public {
        MockERC20(weth).mint(user, STARTING_USER_BALANCE);

        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);

        engine.depositCollateral(weth, STARTING_USER_BALANCE);
        vm.stopPrank();

        //Check if user's balance collateral was properly updated
        uint256 collateralDeposited = engine.s_collateralDeposited(user, weth);
        assertEq(collateralDeposited, STARTING_USER_BALANCE);

        uint256 contractBalance = MockERC20(weth).balanceOf(address(engine));
        assertEq(contractBalance, STARTING_USER_BALANCE);
    }

    function testBorrow() public {
        // deposit funds
        MockERC20(weth).mint(user, amountOfWethCollateral);
        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), amountOfWethCollateral);
        engine.depositCollateral(weth, amountOfWethCollateral);

        // test first borrow
        vm.warp(block.timestamp + 12 seconds);
        uint256 borrowAmount = 1e18;
        engine.borrow(borrowAmount);
        uint256 userKc = engine.getUserKcBalance(user);
        assertEq(userKc, borrowAmount);

        vm.stopPrank();
    }
    function testBorrowOverflow () public {
        MockERC20(weth).mint(user, STARTING_USER_BALANCE);
        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);
        engine.depositCollateral(weth, STARTING_USER_BALANCE);

        uint256 maximumBorrow = engine.getTotalBorrowableAmount(user);

        vm.expectRevert('Borrowed amount cannot exceed collateral');
        engine.borrow(maximumBorrow);
        vm.warp(block.timestamp + 12 seconds);
        vm.stopPrank();
    }

    function testFeesGeneration () public {
       // deposit funds
        MockERC20(weth).mint(user, amountOfWethCollateral);
        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), amountOfWethCollateral);
        engine.depositCollateral(weth, amountOfWethCollateral);

        // test first borrow
        vm.warp(block.timestamp + 4 hours);
        uint256 borrowAmount = 3e18;
        engine.borrow(borrowAmount);

        uint256 initialFees = engine.getUserOwedAmount();

        vm.warp(block.timestamp + 1835 days);
        uint256 fees = engine.getUserOwedAmount();

        console.log('==> fees',fees);

        vm.stopPrank();
    }

    function testHealthFactorUndercollateralized() public {
        //Borrow maximum amount of tokens, wait a bit
        //for fees to occur and expect broken health factor
       MockERC20(weth).mint(user, STARTING_USER_BALANCE);
        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);
        engine.depositCollateral(weth, STARTING_USER_BALANCE);
        uint256 maximumBorrow = engine.getTotalBorrowableAmount(user);

        engine.borrow(maximumBorrow - 1);
        uint256 kcAmount = engine.getUserKcBalance(user);

        vm.warp(block.timestamp + 4 hours);

        bool healthFactor = engine.revertIfHealthFactorIsBroken(user);
        assertEq(healthFactor, true);
        vm.stopPrank();
    }

    function testHealthFactorOvercollateralized() public {
        //Borrow maximum amount of tokens, wait a bit
        //for fees to occur and expect broken health factor
       MockERC20(weth).mint(user, STARTING_USER_BALANCE);
        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);
        engine.depositCollateral(weth, STARTING_USER_BALANCE);
        uint256 maximumBorrow = engine.getTotalBorrowableAmount(user);

        engine.borrow(maximumBorrow/2);
        uint256 kcAmount = engine.getUserKcBalance(user);

        vm.warp(block.timestamp + 4 hours);

        bool healthFactor = engine.revertIfHealthFactorIsBroken(user);
        assertEq(healthFactor, false);
        vm.stopPrank();
    }

     function testMint() public {
         // Mint some tokens for the user
        MockERC20(weth).mint(user, STARTING_USER_BALANCE);
    }   
}