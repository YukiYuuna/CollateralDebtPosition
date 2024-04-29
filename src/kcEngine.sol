// License-Identifier: MIT

import {ICDP} from "./interfaces/ICDP.sol";
import {kcCoin} from './kcCoin.sol';
pragma solidity ^0.8.21;
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';

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
contract kcEngine is kcCoin, ReentrancyGuard {
    ////////////
    // Errors //
    ////////////
    error kcEngine__AmountShouldBeMoreThanZero();
    error kcEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error kcEngine__TokenNotSupported();
    error kcEngine__TransferFailed();
    error KCEngine__MintReverted();
    ////////////
    // State ///
    ////////////

    struct CollateralToken {
        address priceFeedAddresses;
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
    uint256 private constant INTEREST_PER_SHARE_PER_SECOND = 3_170_979_198; // positionSize/10 = positionSize *
        // seconds_per_year * interestPerSharePerSec


    // @dev mapping to hold user borrow info for each user
    mapping(address => UserBorrows) public s_userBorrows;
    // hold of ltv ratios aka how much % each user can mint
    mapping (address => uint256) private s_collateralTokenAndRatio;
    // @dev token to priceFeed
    mapping(address token => address priceFeed) private s_priceFeeds; 
     /// @dev Mapping of token address to collateral token struct
    mapping(address tokenAddress => CollateralToken) private s_collateralTokenData;
    // @dev mapping of user to amount he has deposited of each token
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    // @dev mapping of the amount of kc minted by specific user
    mapping(address user => uint256 amountKcMinted) private s_kcMinted; 
    kcCoin private immutable i_kcStableCoin;
    //The types of tokens the system allows
    address[] s_collateralTokens;

    ///////////
    //Events///
    ///////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
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
        if(s_priceFeeds[token] == address(0)) {
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
        if(tokenAddresses.length != priceFeedAddresses.length || tokenAddresses.length != ltvRatio.length) {
            revert kcEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for(uint256 i = 0; i< priceFeedAddresses.length; i++) {
            s_collateralTokenData[tokenAddresses[i]] = CollateralToken(tokenAddresses[i],decimal[i] , ltvRatio[i]);

            s_collateralTokenAndRatio[tokenAddresses[i]] = ltvRatio[i];
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_kcStableCoin = kcCoin(kcAddress);

    }

    ////////////
    //External/
    ////////////

    function depositCollateralAndMintKc() public {}

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
    ) external moreThanZero(amountCollateral) isAllowedToken(collateralToken) nonReentrant {
        s_collateralDeposited[msg.sender][collateralToken] += amountCollateral;
        emit CollateralDeposited(msg.sender, collateralToken, amountCollateral);

        bool success = IERC20(collateralToken).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success) {
            revert kcEngine__TransferFailed();
        }
    }

    function redeemCollateralForKc() external {}

    function redeemCollateral() public {}

    /**
     * @dev Borrow protocol stablecoins against the caller's collateral.
     *
     * @notice The caller is not allowed to exceed the ltv ratio for their basket of collateral.
     *
     * @param amount the amount to borrow.
     */

    function borrow(uint256 amount) external moreThanZero(amount) nonReentrant {
        uint256 maxBorrowAmount = getTotalBorrowableAmount();
        uint256 userBorrowAmount = s_userBorrows[msg.sender].borrowAmount;

        if(userBorrowAmount == 0) {
            require(amount < maxBorrowAmount, 'Borrowed amount cannot exceed collateral'); 
            s_userBorrows[msg.sender].borrowAmount = amount;
            s_userBorrows[msg.sender].lastPaidAt = block.timestamp;

            mintKc(amount);
            emit kcBorrowed(msg.sender, amount);
        }

        require(userBorrowAmount + amount < maxBorrowAmount, 'Exceeding collateral');
        s_userBorrows[msg.sender].borrowAmount += amount;
        s_userBorrows[msg.sender].lastPaidAt = block.timestamp;
        mintKc(amount);

        emit kcBorrowed(msg.sender, amount);    
    }

    function mintKc(uint256 amountKcToMint) public moreThanZero(amountKcToMint) nonReentrant {
        s_kcMinted[msg.sender] += amountKcToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_kcStableCoin.mint(msg.sender, amountKcToMint);

        if(!minted) {
            revert KCEngine__MintReverted();
        }
    }

    /**
     * @dev Repay protocol stablecoins from the caller's debt.
     * 
     * @param amount the amount to repay.
 */
    function repay(uint256 amount) external {

        i_kcStableCoin.burn(amount);
    }

    function liquidate() external {}

    function getHealthFactor() external {}

    ////////////////////////////////
    //Private & internal functions//
    ////////////////////////////////

    function _healthFactor(address user) private view returns (bool isBroken) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold;
        isBroken = false;
        //Needed adjustmet to keep the collateral a valid number -> example
          for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 tokenAmount = s_collateralDeposited[msg.sender][token];
            uint256 fullPrice = getPriceInUSDForTokens(token, tokenAmount);
            collateralAdjustedForThreshold = (collateralValueInUsd * s_collateralDeposited[msg.sender][token]) / LIQUIDATION_PRECISION;
            //300kc = 300$, 
            //100 ether -> 10000$ 
            // 10 000 / 300 -> 33.33
        }
        // 1000$ of eth and 100 kcCoin  -> 1000 * 50 = 50 000 / 100 = 500 / 100 > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }   

    function _getAccountInformation(address user) private view returns (uint256, uint256) {
        uint256 totalKcMinted = s_kcMinted[user];
        uint256 totalCollateralValueInUsd = getTotalBorrowableAmount();
        
    }

    function _getFeesForPosition(address user) private returns (uint256 totalFee) {
        require(s_userBorrows[user].borrowAmount != 0, 'User has not borrowed yet');
        s_userBorrows[user].refreshedAt = block.timestamp;

        totalFee = s_userBorrows[user].borrowAmount * INTEREST_PER_SHARE_PER_SECOND * (block.timestamp - s_userBorrows[user].lastPaidAt);
        s_userBorrows[user].debt = totalFee;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userBorrowsAmount = getTotalBorrowableAmount(user);      
        uint256 fees = _getFeesForPosition(user);
    }
    
    ////////////////////////////////
    //Public  & external functions//
    ////////////////////////////////

    function getPriceInUSDForTokens(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (uint256(price) * EQUALIZER_PRECISION * amount) / PRECISION;
    }

    function getTotalBorrowableAmount(address user) public view returns (uint256 amount) {
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
