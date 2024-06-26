// SPDX-License-Identifier: MIT


pragma solidity 0.8.21;
import {ILiquidationCallback} from "./ILiquidationCallback.sol";

interface ICDP {
    /**
     * @dev Deposit the specified collateral into the caller's position.
     * Only supported collateralToken's are allowed.
     *
     * @param collateralToken the token to supply as collateral.
     * @param amount the amount of collateralToken to provide.
     */
    function depositCollateral(address collateralToken, uint256 amount) external;

    /**
     * @dev Withdraw the specified collateral from the caller's position.
     *
     * @param collateralToken the token to withdraw from collateral.
     * @param amount the amount of collateral to withdraw.
     */
    function withdrawCollateral(address collateralToken, uint256 amount) external;

    /**
     * @dev Borrow protocol stablecoins against the caller's collateral.
     *
     * @notice The caller is not allowed to exceed the ltv ratio for their basket of collateral.
     *
     * @param amount the amount to borrow.
     */
    function borrow(uint256 amount) external;

    /**
     * @dev Repay protocol stablecoins from the caller's debt.
     *
     * @param amount the amount to repay.
     */
    function repay(uint256 amount) external;

    /**
     * @dev Liquidate a position that has breached the LTV ratio for it's basket of collateral.
     *
     * @param user the user who's position should be liquidated.
     * @param liquidationCallback the liquidation callback contract to send collateral to.
     */
    function liquidate(address user, ILiquidationCallback liquidationCallback) external;
}