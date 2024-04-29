//License-Identifier: MIT

pragma solidity ^0.8.18;
import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
* @title KC Coin
* @author Blagovest Georgiev
* Collateral: Exoogenous (ETC and BTC)
* minting (Stability Mechanism): Algorithmic
* Stability(Relative): Pegged to USD
*
* This is the contract that is meant to be goverened by the KCEngine
* This contract is just the ERC20 implementation of our stablecoin system
*/

contract kcCoin is ERC20Burnable, Ownable {
    error kcCoin__AmountMustBeGreaterThanZero();
    error kcCoin__BurnAmountExceedsBalance();
    error kcCoin__NotZeroAddress();

    constructor() ERC20("Kaiba Corp Coin", 'kcCoin') Ownable(msg.sender){}
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if(_amount <= 0) {
            revert kcCoin__AmountMustBeGreaterThanZero();
        }
        if(balance < _amount) {
            revert kcCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns(bool){
        if(_to == address(0)) {
            revert kcCoin__NotZeroAddress();
        }
        if( _amount <= 0) {
            revert kcCoin__AmountMustBeGreaterThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}