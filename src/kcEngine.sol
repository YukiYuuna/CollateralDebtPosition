// SPDX-License-Identifier: MIT

import {ICDP} from "./interfaces/ICDP.sol";
import {kcCoin} from "./kcCoin.sol";
pragma solidity ^0.8.21;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import { ILiquidationCallback } from './interfaces/ILiquidationCallback.sol';
import './kcGovernanceCoin.sol';

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
contract kcEngine is Ownable {
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
    uint256 private LIQUIDATION_REWARD = 5;
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
    
    //@dev keeps the address of governance engine for permissions
    address governanceAddress;

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
    event borrowedAmountRepaid(address indexed user, uint256 indexed amount);

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
    ) Ownable(msg.sender) {
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

    modifier onlyGovernance() {
        if (governanceAddress != msg.sender) {
            revert ("Function must be executed through governance execute");
        }
        _;
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
                (collateralAfterWithdrawal - amountBorrowed) * tokenData.ltvRatio / LIQUIDATION_PRECISION;
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

    function borrow(uint256 amount) external moreThanZero(amount) {
        uint256 maxBorrowAmount = getTotalBorrowableAmount(msg.sender);
        uint256 userBorrowAmount = s_userBorrows[msg.sender].borrowAmount;
        //

        if (userBorrowAmount == 0) {
            require(
                amount < maxBorrowAmount,
                "Borrowed amount cannot exceed collateral"
            );
            s_userBorrows[msg.sender].borrowAmount = amount;
            s_userBorrows[msg.sender].lastPaidAt = block.timestamp;

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
        if(secondsPassed >= 5 hours) {
            revert ("Update your position");
        }
        uint256 borrowAmount = s_userBorrows[msg.sender].borrowAmount;
        uint256 fees = s_userBorrows[msg.sender].debt;

        if(amount != (borrowAmount + fees)) {
            revert ("User must payback the exact amount of debt");
        }
     
        delete s_userBorrows[msg.sender];
        bool success = i_kcStableCoin.transferFrom(msg.sender, address(this), amount);

        if(!success) {
            revert KCEngine__MintReverted();
        }
        i_kcStableCoin.burn(amount);

        emit borrowedAmountRepaid(msg.sender, amount);

    }

    //0. Check if user is liquidateble;
    //1. Get the user's collateral deposited
    //2. Remove his position from each deposited collateral
    //3. Diversify his collateral to engine and liquidator     

    function liquidate(address user) external {
// get the crab borrowed
        uint256 amountOfKcBorrowed = getUserKcBalance(user);
        uint256 fees = _getFeesForPosition(user);
        if (amountOfKcBorrowed + fees == 0) {
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

        if(userMaxBorrow > amountOfKcBorrowed + fees) {
            revert("User has not exceeded LTV");
        }
        
        uint256 collateralLiquidated = 0;        
        uint256 collateralToLiquidate = amountOfKcBorrowed;
        
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

            //1.Alice repays position debt ENTIRE DEBT
            //2. Reward Alice from 900kc to 900$ worth of ETH 1-> 1
            //3. Reward alice from 5% from entire position -> 5% of 1ETH
            //4. Borrow must be deleted
            //5. Add remeaning to collateral debt deposited or som shi ;3
            IERC20(s_collateralTokens[i]).transfer(msg.sender, collateralToLiquidateInToken);

            i_kcStableCoin.transferFrom(msg.sender, address(this), amountOfKcBorrowed);
            
            s_userBorrows[msg.sender].borrowAmount -= amountOfKcBorrowed;
            collateralLiquidated += collateralToLiquidateInToken; 
        }

        // update borrowed balance and reset user
        delete s_userBorrows[user];
        i_kcStableCoin.burn(amountOfKcBorrowed);

        emit CollateralRedeemed(user, address(this), address(0), collateralLiquidated);
    }

    ////////////////////////////////
    //Private & internal functions//
    ////////////////////////////////

    // @dev check the fees for any user's position 
    // Updates refreshedAt for new fees
    function _getFeesForPosition (address user) public returns (uint256 totalFee) {
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

    function setLiquidationCallbackAddress(address addr) external onlyOwner {
        liquidationAddress = addr;
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

        CollateralToken storage tokenData = s_collateralTokenData[token];
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * EQUALIZER_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        // price of eth or token
        // $/Eth ??, 1000$ / ETH = 0.5eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return
            ((usdAmountInWei * PRECISION) / (uint256(price) *
            EQUALIZER_PRECISION));
    }

    function getUserOwedAmount() public returns (uint256) {
        return s_userBorrows[msg.sender].borrowAmount + _getFeesForPosition(msg.sender);
    }

    function updateLtvRatios(address ltvRatioAddress, uint256 ltvAmount) public onlyGovernance {
        s_collateralTokenAndRatio[ltvRatioAddress] = ltvAmount;
    }

    function getTotalBorrowableAmount(
        address user
    ) public view returns (uint256 amount) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 tokenAmount = s_collateralDeposited[user][token];
            uint256 fullPrice = getPriceInUSDForTokens(token, tokenAmount);

            amount += fullPrice * s_collateralTokenAndRatio[token] / 100 ;
        }
    }

    function getUserKcBalance(address user) public view returns (uint256) {
        return s_userBorrows[user].borrowAmount;
    }

    function setKcGovernanceAddress(address govAddress) external onlyOwner {
        governanceAddress = govAddress;
    }

    /**
     * @dev Liquidate a position that has breached the LTV ratio for it's basket of collateral.
     *
     * @param user the user who's position should be liquidated.
     * 
     * @param liquidationCallback the liquidation callback contract to send collateral to.
     */

     function liquidateWithUniswap(address user, ILiquidationCallback liquidationCallback) external { 
        // get the crab borrowed
        uint256 amountOfKcBorrowed = getUserKcBalance(user);
        uint256 fees = _getFeesForPosition(user);
        if (amountOfKcBorrowed + fees == 0) {
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

        if(userMaxBorrow > amountOfKcBorrowed + fees) {
            revert("User has not exceeded LTV");
        }
        
        uint256 collateralLiquidated = 0;        
        uint256 liquidationReward = amountOfKcBorrowed * LIQUIDATION_REWARD / LIQUIDATION_PRECISION;
        uint256 collateralToLiquidate = amountOfKcBorrowed + liquidationReward;
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
        delete s_userBorrows[user];
        
        i_kcStableCoin.burn(amountOfKcBorrowed);
        emit CollateralRedeemed(user, address(liquidationCallback), address(0), collateralLiquidated);
    }

}




