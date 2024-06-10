//SPDX-License-Identifier: MIT

pragma solidity 0.8.21;
import {Test, console} from 'forge-std/Test.sol';
import {DeployKC} from '../../script/DeployKC.s.sol';
import {kcCoin} from '../../src/kcCoin.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {kcEngine} from '../../src/kcEngine.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {kcGovernance} from '../../src/kcGovernanceCoin.sol';
import {LiquidationCallback} from '../../src/LiquidationCallback.sol';

contract kcEngineTest is Test {
    error kcEngine__testMismatchingUsdConvertor();
    
    DeployKC deployer;
    HelperConfig helperConfig;
    kcCoin kc;
    kcEngine engine;
    kcGovernance governance;
    LiquidationCallback liquidationCB;

    address weth;
    address wethUsdPriceFeed;
    address usdc;
    address usdcUsdPriceFeed;

    address public user = address(1);
    address alice = makeAddr("alice");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 amountOfWethCollateral = 15 ether;

    function setUp() public {
        deployer = new DeployKC();
        (kc, engine, helperConfig, governance) = deployer.run();
        liquidationCB = new LiquidationCallback(address(kc), address(engine), usdc);
        (wethUsdPriceFeed, weth,,,,,) = helperConfig.activeNetworkConfig();
        vm.deal(user, STARTING_USER_BALANCE);
        vm.deal(alice, STARTING_USER_BALANCE);
        vm.prank(alice);
        engine.setLiquidationCallbackAddress(address(liquidationCB));
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
        console.log('expect usd',expectedUsd/1e18);
        console.log('actual usd',actualUsd/1e18);
        assertEq(expectedUsd, actualUsd);
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
        uint256 borrowAmount = 4e18;
        engine.borrow(borrowAmount);
        uint256 userKc = engine.getUserKcBalance(user);
        console.log('==> user KC',userKc/1e18);
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
        MockERC20(weth).mint(alice, STARTING_USER_BALANCE);
        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);
        engine.depositCollateral(weth, STARTING_USER_BALANCE);
        uint256 maximumBorrow = engine.getTotalBorrowableAmount(user);

        engine.borrow(maximumBorrow - 1);
        uint256 kcAmount = engine.getUserKcBalance(user);
        console.log('===> kc amount',kcAmount/1e18);
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
function testRepay() public {
        // deposit funds
        MockERC20(weth).mint(user, 15 ether);

        // Approve the CrabEngine contract to spend the user's tokens
        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), 2 ether);
        engine.depositCollateral(weth, 1 ether);

        vm.warp(block.timestamp + 12 seconds);
        engine.borrow(1 ether);

        vm.warp(block.timestamp + 12 seconds);
        uint256 owedAmount = engine.getUserOwedAmount();
        vm.stopPrank();
        kc.balanceOf(user);
        // give the user funds to pay back
        vm.prank(address(engine));
        kc.mint(user, owedAmount);
        // pay properly
        vm.startPrank(user);
        kc.approve(address(engine), owedAmount);
        engine.repay(owedAmount);
        vm.stopPrank();
    }

    function testLiquidate() public {
        // Setup: Mint some tokens for the user and deposit them as collateral
        // ...
        MockERC20(weth).mint(user, STARTING_USER_BALANCE);
        MockERC20(weth).mint(alice, STARTING_USER_BALANCE);

        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);
        engine.depositCollateral(weth, 1 ether);
        uint256 maxBorrowAmount = engine.getTotalBorrowableAmount(user);

        engine.borrow(maxBorrowAmount-999);
        vm.warp(block.timestamp + 3 hours);
        bool healthFactor = engine.revertIfHealthFactorIsBroken(user);
        console.log(healthFactor);
        vm.stopPrank();

        vm.startPrank(alice);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);

        engine.depositCollateral(weth, 4 ether);
        uint256 maxBorrowAmountAlice = engine.getTotalBorrowableAmount(alice);
        engine.borrow(maxBorrowAmountAlice-999);
        kc.approve(address(engine), UINT256_MAX);
        console.log('===> b4 liquidation',MockERC20(weth).balanceOf(alice)/1e18);

        engine.liquidate(user);
        console.log('===> After liquidation',MockERC20(weth).balanceOf(alice)/1e17);


        console.log('==> user new value',engine.getTotalBorrowableAmount(user));
        vm.stopPrank();
    }
}