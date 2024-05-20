//SPDX-License-Idenfitier: MIT

pragma solidity ^0.8.21;
import { ERC20Votes } from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol';
import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IGov } from './interfaces/IGov.sol';
import { kcEngine } from './kcEngine.sol';

contract kcGovernance is ERC20 {
    kcEngine private i_kcEngine;
    uint256 proposalId = 0;
    Proposal[] proposals;
    
    mapping(address => uint256) private s_userVotingPower;
    mapping(address => mapping(uint256 => bool)) private s_userHasVoted;

    struct Proposal { 
        bool executed;
        address caller;
        address token;
        uint256 ltv;
        uint256 yesVotes;
        uint256 endTime;
    }

    constructor(address kcEngineAddress)ERC20('kcGovernance','kGov') {
        i_kcEngine = kcEngine(kcEngineAddress);
    }

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert ("Amount has to be gr8ter than zero");
        }
        _;
    }
    
    function mint(uint256 _amount, address _to) public moreThanZero(_amount) returns (bool) {
        _mint(_to, _amount);
        return true;
    }

    function addVotesToUser() external {
        uint256 userOwedBalance = i_kcEngine.getUserOwedAmount();
        bool isMinted = mint(userOwedBalance, msg.sender);
        s_userVotingPower[msg.sender] = userOwedBalance;
    }

      /**
     * @dev Create a proposal for an ltv ratio for a supported collateral token.
     * Requires that the proposer holds > 1% of the totalSupply of the governance token.
     *
     * @notice proposer automatically votes for the proposal with their entire balance.
     *
     * @param token the supported collateral token for which to propose a ltv ratio for.
     * @param ltv the proposed ltv ratio.
     * @return proposalId the id of the proposal.
     */
    function propose(address token, uint256 ltv) external returns (uint256 proposalId) {
        proposalId++;

        if(ltv > 99) {
            revert("kc Engine ratios cannot go over 99");
        }

        proposals[proposalId] = Proposal({
            executed: false,
            caller: msg.sender,
            token: token,
            ltv: ltv,
            yesVotes: 0,
            endTime: block.timestamp + 5 days
        });
    }

    /**
     * @dev Vote for a proposal with the governance token balance of the caller.
     * Requires that the proposal corresponding to the proposalId is currently active.
     *
     * @param proposalId the id corresponding to the proposal to vote for.
     */
    
    function vote(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if(block.timestamp < proposal.endTime) {
            revert ("Proposal has expired");
        }        

        proposal.yesVotes += balanceOf(msg.sender);
        s_userHasVoted[msg.sender][proposalId] = true;
    }

    function execute (uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if(block.timestamp > proposal.endTime) {
            revert ("Proposal has not yet ended");
        }

        if(proposal.executed) {
            revert ("Proposal is already executed");
        }

        if(proposal.yesVotes < totalSupply() / 2 ) {
            revert ("Not enough people have voted");
        }

        proposal.executed = true;
        i_kcEngine.updateLtvRatios(proposal.token, proposal.ltv);
    }

    function getProposal (uint256 proposalId) external {

    }
}

//snapshot of token ppl have at certain block