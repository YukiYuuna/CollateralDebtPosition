// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Test, console } from "forge-std/Test.sol";
import { kcGovernance } from "../../src/kcGovernanceCoin.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import {kcCoin} from '../../src/kcCoin.sol';
import {DeployKC} from '../../script/DeployKC.s.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {kcEngine} from '../../src/kcEngine.sol';


contract KCGovernanceCoinTest is Test {
    DeployKC deployer;
    HelperConfig helperConfig;
    kcCoin kc;
    kcEngine engine;
    kcGovernance governance;
    MockERC20 mockERC20;

    address wethUsdPriceFeed;
    address weth;
    address dummyToken = address(0x1); // Dummy token address for testing
    address user1;
    address user2;
    address user3;
    

    address alice = makeAddr("alice");
    address public user = address(1);
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 amountOfWethCollateral = 15 ether;


    function setUp() public virtual {
        
        //deploy crabenigne
        deployer = new DeployKC();
        (kc, engine, helperConfig, governance) = deployer.run();
        (wethUsdPriceFeed, weth,,,,,) = helperConfig.activeNetworkConfig();
        vm.deal(user, STARTING_USER_BALANCE);
        vm.deal(alice, STARTING_USER_BALANCE);
        vm.prank(alice);
        // ---  

        user1 = address(1);
        user2 = address(2);
        user3 = address(3);
        user3 = address(4);

        // deploying contracts and minting for user
        mockERC20 = new MockERC20("MockERC20", "MOCK");
        // get the stakedcoin address
        governance.mint(12_000, user1); // Mint 12000 stablecoins to user1
        governance.mint(5000, user2); // Mint 5000 stablecoins to user2
        vm.stopPrank();
        
    }

    function _makeProposal(address user) internal returns (uint256 proposalId) {
        uint256 proposalId = governance.propose(weth, 70);
        console.log('new proposal with id',proposalId);
    }

    function testPropose() public {
        console.log("testPropose");
        uint256 newLtvRatio = 50;
        uint256 proposalId = governance.propose(weth, newLtvRatio);
        (bool executed, address proposer, uint256 ltv,,,) = governance.getProposal(proposalId);

        assertEq(executed, false, "Executed is not correct");
        assertEq(proposer, address(this), "proposer is the same");
        assertEq(newLtvRatio, ltv, "New ratio");
    }

    function testVote() public {
        // create a new proposal
        uint256 newLtvRatio = 50;
        uint256 proposalId = governance.propose(weth, newLtvRatio);

        //  Vote on the proposal
        vm.startPrank(user2);
        governance.vote(proposalId);
        vm.stopPrank();

        (,,,, uint256 yesVotes,) = governance.proposals(proposalId);
        assertEq(yesVotes, 5_000, "Vote was not recorded");
    }

    function testRevertMultipleVotes() public {
          // create a new proposal
        uint256 newLtvRatio = 50;
        uint256 proposalId = governance.propose(weth, newLtvRatio);

        //  Vote on the proposal
        vm.startPrank(user2);
        governance.vote(proposalId);
        governance.vote(proposalId);

        vm.expectRevert("User has already voted on this proposal");
      
        vm.stopPrank();

        (,,,, uint256 yesVotes,) = governance.proposals(proposalId);
        assertEq(yesVotes, 5_000, "Vote was not recorded");
    }

    function testAddingVotesInvalidOwner() public {
        vm.startPrank(user2);
        governance.addVotesToUser(user2, 300);
        vm.stopPrank();
        vm.expectRevert();
    }

    function testAddingVotesToUsers() public {
        console.log('alice address',alice);
        vm.startPrank(alice);
        governance.addVotesToUser(user2, 300);
        vm.stopPrank();
    }

    function testExecute() public {
        uint256 newLtvRatio = 50;
        uint256 proposalId = governance.propose(weth, newLtvRatio);
        //Let owner give all the voting power to 1 person so he has over 50%
        vm.startPrank(alice);
        governance.addVotesToUser(user2, 999999);
        vm.stopPrank();
        //  Vote on the proposal
        vm.startPrank(user2);
        governance.vote(proposalId);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        
        governance.execute(proposalId);

    }

    // function testRevertDoubleVote() public {
    //     // create a new proposal
    //     uint256 proposalId = _makeProposal(user1);

    //     //  Vote on the proposal
    //     vm.startPrank(user2);
    //     claw.vote(proposalId);
    //     vm.stopPrank();

    //     (,,,, uint256 yesVotes,,) = claw.proposals(proposalId);
    //     assertEq(yesVotes, 17_000, "Vote was not recorded");

    //     // should revert if user votes again
    //     vm.startPrank(user2);
    //     vm.expectRevert("User has already voted on this proposal");
    //     claw.vote(proposalId);
    //     vm.stopPrank();
    // }

    // function testRevertNoTokenToVote() public {
    //     // create a new proposal
    //     uint256 proposalId = _makeProposal(user1);

    //     //  Vote on the proposal
    //     vm.startPrank(user3);
    //     vm.expectRevert("No governance tokens to vote with");
    //     claw.vote(proposalId);
    //     vm.stopPrank();
    // }

    function testBurn() public {
        governance = new kcGovernance(address(engine));
        address account = address(this);
        uint256 amountToMint = 1000;
        uint256 amountToBurn = 500;

        governance.mint(amountToMint,account);
        uint256 initialBalance = governance.balanceOf(account);

        governance.burn(amountToBurn);

        uint256 finalBalance = governance.balanceOf(account);
        assert(finalBalance == initialBalance - amountToBurn);
    }

    function testMint() public {
        governance = new kcGovernance(address(engine));
        address recipient = address(this);
        uint256 initialBalance = governance.balanceOf(recipient);
        uint256 amountToMint = 1000;

        governance.mint(amountToMint,recipient);

        uint256 finalBalance = governance.balanceOf(recipient);
        assert(finalBalance == initialBalance + amountToMint);
    }
}