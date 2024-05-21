// SPDX-License-Identifier: MIT

import {ICDP} from "./interfaces/ICDP.sol";
import {kcCoin} from "./kcCoin.sol";
pragma solidity ^0.8.21;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Test, console} from "forge-std/Test.sol";
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import { ILiquidationCallback } from './interfaces/ILiquidationCallback.sol';

/*
 *   @title kcEngine
 *   This system is designed to keep a 1 token === $1 peg.
 *   The system has the following properties
 *   -Exogenous collateral
 *   -Dollar pegged
 *   -Algorithmically Stable
 *
 *   The system should always keep more collateral than kc stablecoins, as the collateral
 *   backs up the system.
 *   It is simmilar to DAI, but backed by wETH and wBTC
 *
 *   @notice this is the core of the systems, it handles all logic of minting and and redeeming kcCoins, as well as
 *   depositing and withdrawing collateral
 *   @notice the governance is decentralized
 *   @notice the fees are calculated per year as according to IGov stake contract
 *
 */
contract kcEngine is Ownable,kcCoin,ReentrancyGuard {
    ////////////
    // Errors //
    ////////////
    error kcEngine__AmountShouldBeMoreThanZero();
    error kcEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error kcEngine__TokenNotSupported();
    error kcEngine__TransferFailed();
    error KCEngine__MintReverted();
    error KCEngine__UserHasNotBorrowedKc();
    error KCEngine__UserHasBrokenHealthFactor();

    using OracleLib for AggregatorV3Interface;

    ////////////
    // State ///
    ////////////

    struct CollateralToken {
        address priceFeedAddress;
        uint8 decimals;
        uint8 ltvRatio;
    }

    /// @dev struct that holds borrow information for the user
    struct UserBorrows {
        uint256 lastPaidAt; // last time fees were accumulated
        uint256 borrowAmount; // total borrowed value without interest
        uint256 debt; // owed fees
        uint256 refreshedAt; // time at which fees were last calculated
    }

    uint256 private constant EQUALIZER_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private LIQUIDATION_REWARD = 500;
    uint256 private constant INTEREST_PER_SHARE_PER_SECOND = 3_170_979_198; // positionSize/10 = positionSize *
    // seconds_per_year * interestPerSharePerSec

    // @dev mapping to hold user borrow info for each user
    mapping(address => UserBorrows) public s_userBorrows;

    // @dev mapping of ltv ratios aka how much % each user can mint
    mapping(address => uint256) private s_collateralTokenAndRatio;

    // @dev token to priceFeed
    mapping(address token => address priceFeed) private s_priceFeeds;

    /// @dev Mapping of token address to collateral token struct
    mapping(address tokenAddress => CollateralToken)
        private s_collateralTokenData;

    // @dev mapping of user to amount he has deposited of each token
    mapping(address user => mapping(address token => uint256 amount)) public s_collateralDeposited;

    kcCoin private immutable i_kcStableCoin;
    //The types of tokens the system allows
    address[] s_collateralTokens;
    // @dev Keeps track of total debt accumulated in the contract
    uint256 s_protocolDebtInKc;
    
    // @dev keeps track of accumulated fees in the protocol
    uint256 s_protocolFees;

    address public liquidationAddress = address(0);

    ///////////
    //Events///
    ///////////

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);
    event kcBorrowed(address indexed user, uint256 indexed amount);

    ////////////
    //Modifier//
    ////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert kcEngine__AmountShouldBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert kcEngine__TokenNotSupported();
        }
        _;
    }

    ////////////
    //Functions/
    ////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        uint8[] memory decimal,
        uint8[] memory ltvRatio,
        address kcAddress
    ) {
        //This follows USD Price feed -> Eth/USD, Btc/USD
        if (
            tokenAddresses.length != priceFeedAddresses.length ||
            tokenAddresses.length != ltvRatio.length
        ) {
            revert kcEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < priceFeedAddresses.length; i++) {
            s_collateralTokenData[tokenAddresses[i]] = CollateralToken(
                priceFeedAddresses[i],
                decimal[i],
                ltvRatio[i]
            );

            s_collateralTokenAndRatio[tokenAddresses[i]] = ltvRatio[i];
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_kcStableCoin = kcCoin(kcAddress);
    }

    ////////////
    //External/
    ////////////

    /**
     * @dev Deposit the specified collateral into the caller's position.
     * Only supported collateralToken's are allowed.
     *
     * @param collateralToken the token to supply as collateral.
     * @param amountCollateral the amount of collateralToken to provide.
     */
    
    function depositCollateral(
        address collateralToken,
        uint256 amountCollateral
    )
        external
        moreThanZero(amountCollateral)
        isAllowedToken(collateralToken)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralToken] += amountCollateral;
        emit CollateralDeposited(msg.sender, collateralToken, amountCollateral);

        bool success = IERC20(collateralToken).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert kcEngine__TransferFailed();
        }
    }

    /**
     * 
     * @param collateralTokenAddress The address of the token user wants to withdraw from
     * his own position to account
     * @param amount  amount of token 
     */
    

    function withdrawCollateral(
        address collateralTokenAddress,
        uint256 amount
    ) public {
        uint256 amountBorrowed = getUserKcBalance(msg.sender);
        CollateralToken memory tokenData = s_collateralTokenData[collateralTokenAddress];

        uint256 collateralAfterWithdrawal = s_collateralDeposited[msg.sender][collateralTokenAddress] - amount;
           uint256 collateralValueRequiredToKeepltv =
                (collateralAfterWithdrawal - amountBorrowed) * tokenData.ltvRatio / 100;
            if (collateralValueRequiredToKeepltv > collateralAfterWithdrawal) {
                revert("Withdrawal would violate LTV ratio");
            }

        s_collateralDeposited[msg.sender][collateralTokenAddress] -= amount;
        IERC20(collateralTokenAddress).transfer(msg.sender, amount);
        emit CollateralRedeemed(msg.sender, msg.sender, address(0), amount);
    }

    /**
     * @dev Borrow protocol stablecoins against the caller's collateral.
     *
     * @notice The caller is not allowed to exceed the ltv ratio for their basket of collateral.
     *
     * @param amount the amount to borrow.
     */

    function borrow(uint256 amount) external moreThanZero(amount) nonReentrant {
        uint256 maxBorrowAmount = getTotalBorrowableAmount(msg.sender);
        uint256 userBorrowAmount = s_userBorrows[msg.sender].borrowAmount;
        console.log("I borrow", userBorrowAmount);

        if (userBorrowAmount == 0) {
            require(
                amount < maxBorrowAmount,
                "Borrowed amount cannot exceed collateral"
            );
            s_userBorrows[msg.sender].borrowAmount = amount;
            s_userBorrows[msg.sender].lastPaidAt = block.timestamp;
            console.log('borrow ==>',s_userBorrows[msg.sender].borrowAmount);

            bool hasBrokenHealthFactor = revertIfHealthFactorIsBroken(
                msg.sender
            );
            if (hasBrokenHealthFactor) {
                revert KCEngine__UserHasBrokenHealthFactor();
            }

            i_kcStableCoin.mint(msg.sender, amount);

            emit kcBorrowed(msg.sender, amount);
        } else {
             require(
            amount +
                s_userBorrows[msg.sender].borrowAmount +
                s_userBorrows[msg.sender].debt <
                maxBorrowAmount,
            "Amount exceeds collateral borrow value"
        );

        s_userBorrows[msg.sender].borrowAmount += amount;
        s_userBorrows[msg.sender].lastPaidAt = block.timestamp;
        s_protocolDebtInKc += amount;

        bool minted = i_kcStableCoin.mint(msg.sender, amount);
        if (minted != true) {
            revert KCEngine__MintReverted();
        }
        emit kcBorrowed(msg.sender, amount);
        }
    }

    /**
     * @dev Repay protocol stablecoins from the caller's debt.
     *
     * @param amount the amount to repay.
     */
    function repay(uint256 amount) external {
        uint256 secondsPassed = block.timestamp - s_userBorrows[msg.sender].lastPaidAt;
        if(secondsPassed < 5 hours) {
            revert ("Update your position");
        }

        uint256 borrowAmount = s_userBorrows[msg.sender].borrowAmount;
        uint256 fees = s_userBorrows[msg.sender].debt;

        if(amount != (borrowAmount + fees)) {
            revert ("User must payback the exact amount of debt");
        }

        s_protocolDebtInKc -= amount;
        delete s_userBorrows[msg.sender];
        bool minted = i_kcStableCoin.transferFrom(msg.sender, address(this), amount);
        if(!minted) {
            revert KCEngine__MintReverted();
        }
    }

    //0. Check if user is liquidateble;
    //1. Get the user's collateral deposited
    //2. Remove his position from each deposited collateral
    //3. Diversify his collateral to engine and liquidator

       /**
     * @dev Liquidate a position that has breached the LTV ratio for it's basket of collateral.
     *
     * @param user the user who's position should be liquidated.
     */

     function liquidate(address user, ILiquidationCallback liquidationCallback) external { 
        // get the crab borrowed
        uint256 amountOfCrabBorrowed = getUserKcBalance(user);
        uint256 fees = _getFeesForPosition(user);
        if (amountOfCrabBorrowed + fees == 0) {
            revert("User has no debt");
        }

        // get the total value of the collateral
        uint256 userCollateralValue = 0;
        uint256 userMaxBorrow = 0;
        // loop through all the collateral tokens and get the total value of the collateral
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            // get full price for token and token amount
            uint256 fullPrice = getPriceInUSDForTokens(s_collateralTokens[i], s_collateralDeposited[user][s_collateralTokens[i]]);
            // add the price of the token to the total collateral value
            // to get the total value of the collateral
            userCollateralValue += fullPrice;
            // get max borrow according to LTV ratio
            userMaxBorrow += fullPrice / s_collateralTokenAndRatio[s_collateralTokens[i]];
        }

        if(userMaxBorrow > amountOfCrabBorrowed + fees) {
            revert("User has not exceeded LTV");
        }
        
        uint256 collateralLiquidated = 0;        
        uint256 liquidationReward = amountOfCrabBorrowed * LIQUIDATION_REWARD / 100;
        uint256 collateralToLiquidate = amountOfCrabBorrowed + liquidationReward;
        bool isValidLiquidatorAddress = liquidationAddress == address(liquidationCallback) && address(liquidationCallback) != address(0);
        // loop through all the collateral tokens and liquidate the collateral
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            //get price for token according to amount
            //address token = s_collateralTokens[i];
            //uint256 tokenAmount = s_collateralDeposited[user][token];
            uint256 price = getPriceInUSDForTokens(s_collateralTokens[i], s_collateralDeposited[user][s_collateralTokens[i]]);
            uint256 collateralToLiquidateInToken = collateralToLiquidate * price / userCollateralValue;
            if (collateralToLiquidateInToken >= s_collateralDeposited[user][s_collateralTokens[i]]) {
                collateralToLiquidateInToken = s_collateralDeposited[user][s_collateralTokens[i]];
            }
            // update user collateral
            s_collateralDeposited[user][s_collateralTokens[i]] -= collateralToLiquidateInToken;
            if (isValidLiquidatorAddress) {
                IERC20(s_collateralTokens[i]).transfer(address(liquidationCallback), collateralToLiquidateInToken);
                liquidationCallback.onCollateralReceived(s_collateralTokens[i], collateralToLiquidateInToken);
            }
            // user repays it himself
            else {
                IERC20(s_collateralTokens[i]).transfer(msg.sender, collateralToLiquidateInToken);
                i_kcStableCoin.transferFrom(msg.sender, address(this), price);
            }        
            collateralLiquidated += collateralToLiquidateInToken;            
        }

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            if (liquidationReward <= s_collateralDeposited[user][s_collateralTokens[i]]) {
                IERC20(s_collateralTokens[i]).transfer(msg.sender, liquidationReward);
                break;
            }
        }

        // update borrowed balance and reset user
        s_protocolFees -= amountOfCrabBorrowed;
        delete s_userBorrows[user];
        i_kcStableCoin.burn(amountOfCrabBorrowed);
        emit CollateralRedeemed(user, address(liquidationCallback), address(0), collateralLiquidated);
    }


    ////////////////////////////////
    //Private & internal functions//
    ////////////////////////////////

    // @dev check the fees for any user's position
    function _getFeesForPosition (address user) private returns (uint256 totalFee) {
        require(
            s_userBorrows[user].borrowAmount != 0,
            "User has not borrowed yet"
        );
        s_userBorrows[user].refreshedAt = block.timestamp;

        totalFee =
            (s_userBorrows[user].borrowAmount *
            (INTEREST_PER_SHARE_PER_SECOND) *
            (block.timestamp - s_userBorrows[user].lastPaidAt)) / PRECISION;
        s_userBorrows[user].debt = totalFee;
    }

    function revertIfHealthFactorIsBroken(
        address user
    ) public returns (bool isBroken) {
        uint256 userBorrowedAmount = getUserKcBalance(user);
        if (userBorrowedAmount == 0) {
            return false;
        }
        uint256 fees = _getFeesForPosition(user);
        uint256 userBorrowsLimit = getTotalBorrowableAmount(user);
        if (userBorrowedAmount + fees > userBorrowsLimit) {
            return true;
        }
        return false;
    }

    ////////////////////////////////
    //Public  & external functions//
    ////////////////////////////////

    function getPriceInUSDForTokens(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_collateralTokenData[token].priceFeedAddress
        );

        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return (uint256(price) * EQUALIZER_PRECISION * amount) / PRECISION;
    }

    function getUserOwedAmount() public returns (uint256) {
        return s_userBorrows[msg.sender].borrowAmount + _getFeesForPosition(msg.sender);
    }

    function updateLtvRatios(address ltvRatioAddress, uint256 ltvAmount) public onlyOwner {
        s_collateralTokenAndRatio[ltvRatioAddress] = ltvAmount;
    }

    function getTotalBorrowableAmount(
        address user
    ) public view returns (uint256 amount) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 tokenAmount = s_collateralDeposited[user][token];
            uint256 fullPrice = getPriceInUSDForTokens(token, tokenAmount);

            amount += fullPrice / s_collateralTokenAndRatio[token];
        }
    }

    function getUserKcBalance(address user) public view returns (uint256) {
        return s_userBorrows[user].borrowAmount;
    }
}
