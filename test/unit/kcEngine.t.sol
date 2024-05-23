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
        console.log('expect usd',expectedUsd);
        console.log('actual usd',actualUsd);
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
        MockERC20(weth).mint(alice, STARTING_USER_BALANCE);
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

        // give the user funds to pay back
        vm.prank(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512);
        engine.mint(user, owedAmount);

        // pay properly
        vm.startPrank(user);
        engine.approve(address(engine), owedAmount);
        engine.repay(owedAmount);

        vm.stopPrank();
    }

    function testLiquidate() public {
        // Setup: Mint some tokens for the user and deposit them as collateral
        // ...
        MockERC20(weth).mint(user, STARTING_USER_BALANCE);
        MockERC20(weth).mint(alice, 10 ether);

        vm.startPrank(user);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);
        engine.depositCollateral(weth, 1 ether);
        uint256 maxBorrowAmount = engine.getTotalBorrowableAmount(user);

        engine.borrow(maxBorrowAmount-999);
        vm.warp(3 hours);
        bool healthFactor = engine.revertIfHealthFactorIsBroken(user);
        console.log(healthFactor);
        vm.stopPrank();

        vm.startPrank(alice);
        MockERC20(weth).approve(address(engine), STARTING_USER_BALANCE);
        
        engine.depositCollateral(weth, 5 ether);
        engine.borrow(3 ether);
        engine.approve(address(engine), STARTING_USER_BALANCE);

        engine.liquidateWithUniswap(user, liquidationCB);

        // Test 1: User has no debt
        // ...

        // Test 2: User's collateral value is insufficient to cover the debt
        // ...

        // Test 3: User's collateral value is sufficient to cover the debt
        // ...
    }
}