// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {DeployCoinFlip} from "../../script/DeployCoinFlip.s.sol";
import {CoinFlip} from "../../src/CoinFlip.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "../mocks/VRFCoordinatorV2Mock.sol";

contract CoinFlipTest is Test {
    event SignedUpToCoinFlip(address indexed player);
    event RequestedCoinFlipWinner(uint256 indexed requestId);
    event WinnerPicked(address payable[] indexed winner);

    CoinFlip coinFlip;
    HelperConfig helperConfig;

    uint256 minBet;
    uint256 maxBet;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER1 = makeAddr("player1");
    address public PLAYER2 = makeAddr("player2");

    address public i_owner;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployCoinFlip deployer = new DeployCoinFlip();
        (coinFlip, helperConfig) = deployer.run();
        i_owner = coinFlip.getOwner();
        vm.deal(PLAYER1, STARTING_USER_BALANCE);
        vm.deal(PLAYER2, STARTING_USER_BALANCE);
        vm.deal(i_owner, STARTING_USER_BALANCE); // figure out how to get the
        //owner of the contract

        (
            ,
            gasLane,
            interval,
            minBet,
            maxBet,
            callbackGasLimit,
            vrfCoordinator,
            ,

        ) = helperConfig.activeNetworkConfig();
    }

    modifier contractFunded() {
        vm.prank(i_owner);
        coinFlip.fund{value: STARTING_USER_BALANCE}();

        _;
    }

    modifier usersSignedUp() {
        vm.prank(PLAYER1);
        coinFlip.signUpToCoinFlip();
        vm.prank(PLAYER2);
        coinFlip.signUpToCoinFlip();
        _;
    }

    //constructor
    // function testConstructorSetsStateToOpen() public view {
    //     assert(coinFlip.getCoinFlipState() == CoinFlip.CoinFlipState.OPEN);
    // }

    //signUpToCoinFlip
    function testSignUpToCoinFlipAddsToPlayersArray() public {
        vm.prank(PLAYER1);
        coinFlip.signUpToCoinFlip();
        assertEq(PLAYER1, coinFlip.getPlayerAtIndex(0));
    }

    function testSignUpToCoinFlipEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit SignedUpToCoinFlip(PLAYER1);
        vm.prank(PLAYER1);
        coinFlip.signUpToCoinFlip();
    }

    //fund
    function testFundOwner() public {
        assertEq(address(coinFlip).balance, 0 ether);
        vm.prank(i_owner);
        uint256 fundAmount = 1 ether;
        coinFlip.fund{value: fundAmount}();
        assertEq(address(coinFlip).balance, fundAmount);
    }

    function testFundRevertNonOwner() public {
        vm.expectRevert(CoinFlip.CoinFlip__NonOwnerCantCallFund.selector);
        vm.prank(PLAYER1);
        coinFlip.fund{value: STARTING_USER_BALANCE}();
    }

    //bet
    function testBetRevertWhenNotSignedUp() public contractFunded {
        vm.expectRevert(CoinFlip.CoinFlip__NotSignedUp.selector);
        vm.prank(PLAYER1);
        coinFlip.bet{value: 0.1 ether}();
    }

    function testBetRevertWhenNotEnoughEthSent()
        public
        contractFunded
        usersSignedUp
    {
        vm.expectRevert(CoinFlip.CoinFlip___NotEnoughEthSent.selector);
        vm.prank(PLAYER1);
        coinFlip.bet{value: 0.001 ether}();
    }

    function testBetRevertWhenTooMuchEthSent()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        vm.expectRevert(CoinFlip.CoinFlip__TooMuchEthSent.selector);
        coinFlip.bet{value: maxBet + 1}();
    }

    function testBetRevertWhenNotOpen() public contractFunded usersSignedUp {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        coinFlip.performUpkeep("");

        vm.expectRevert(CoinFlip.CoinFlip__CoinFlipNotOpen.selector);
        vm.prank(PLAYER2);
        coinFlip.bet{value: minBet}();
    }

    function testBetAddToBettersArray() public contractFunded usersSignedUp {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        assertEq(coinFlip.getBetterAtIndex(0), PLAYER1);
    }

    function testBetAddToBettersBetAmountMapping()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        assertEq(coinFlip.getBettersBetAmount(PLAYER1), minBet);
    }

    //CheckUpkeep
    function testCheckUpKeepRevertInsufficientBalance() public usersSignedUp {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        vm.expectRevert(
            CoinFlip.CoinFlip__InsufficientContractBalance.selector
        );
        vm.prank(i_owner);
        coinFlip.checkUpkeep("");
    }

    function testCheckUpKeepFalseInsufficientTimeHasPassed()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();

        (bool upkeepNeeded, ) = coinFlip.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpKeepFalseIsClosed()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        coinFlip.performUpkeep("");

        (bool upkeepNeeded, ) = coinFlip.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpKeepFalseWhenNoBetters()
        public
        contractFunded
        usersSignedUp
    {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = coinFlip.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    //performUpkeep
    function testPerformUpkeepRevertWhenUpkeepNotNeeded()
        public
        contractFunded
        usersSignedUp
    {
        uint256 numBetters = 0;
        uint256 coinFlipState = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                CoinFlip.CoinFlip__UpkeepNotNeeded.selector,
                numBetters,
                coinFlipState
            )
        );
        coinFlip.performUpkeep("");
    }

    function testPerformUpkeepDoesNotRevertWhenUpkeepNeeded()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        coinFlip.performUpkeep("");
    }

    function testPerformUpkeepEmitsRequestWinner()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        vm.recordLogs();
        coinFlip.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        assert(uint256(requestId) > 0);
    }

    function testPerformUpkeepUpdatesState()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        coinFlip.performUpkeep("");

        CoinFlip.CoinFlipState coinFlipState = coinFlip.getCoinFlipState();

        assert(uint(coinFlipState) == 1);
    }

    //fulfillRandomWords

    function testFulfillRandomWordsRevertsBeforePerformUpkeep()
        public
        contractFunded
        usersSignedUp
    {
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            0,
            address(coinFlip)
        );

        vm.expectRevert("nonexistent request");

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            1,
            address(coinFlip)
        );
    }

    function testFulfillRandomWordsWorks() public contractFunded usersSignedUp {
        uint256 startingTimeStamp = coinFlip.getLastTimeStamp();
        vm.prank(PLAYER1);
        coinFlip.bet{value: minBet}();
        vm.prank(PLAYER2);
        coinFlip.bet{value: minBet}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        uint256 contractStartingBalance = address(coinFlip).balance;

        vm.recordLogs();
        coinFlip.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; // get the requestId from the logs

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(coinFlip)
        );
        uint256 contractEndingBalance = address(coinFlip).balance;

        // Assert
        address[] memory recentWinners = coinFlip.getRecentWinners();
        CoinFlip.CoinFlipState coinFlipState = coinFlip.getCoinFlipState();
        uint256 endingTimeStamp = coinFlip.getLastTimeStamp();

        if (
            recentWinners[0] == coinFlip.getOwner() && recentWinners.length == 1
        ) {
            assertEq(contractStartingBalance, contractEndingBalance);
        } else {
            assertEq(address(PLAYER1).balance, STARTING_USER_BALANCE + minBet);
            assertEq(address(PLAYER2).balance, STARTING_USER_BALANCE + minBet);
            assertEq(
                contractStartingBalance - 4 * minBet,
                contractEndingBalance
            );
        }
        assert(uint256(coinFlipState) == 0);
        assert(endingTimeStamp > startingTimeStamp);
    }

    // function testFulfillRandomWordsHouseWin()
    //     public
    //     contractFunded
    //     usersSignedUp
    // {
    //     uint256 startingTimeStamp = coinFlip.getLastTimeStamp();
    //     vm.prank(PLAYER1);
    //     coinFlip.bet{value: minBet}();
    //     vm.prank(PLAYER2);
    //     coinFlip.bet{value: minBet}();
    //     vm.warp(block.timestamp + interval + 1);
    //     vm.roll(block.number + 1);

    //     uint256 contractStartingBalance = address(coinFlip).balance;

    //     vm.recordLogs();
    //     coinFlip.performUpkeep(""); // emits requestId
    //     Vm.Log[] memory entries = vm.getRecordedLogs();
    //     bytes32 requestId = entries[1].topics[1]; // get the requestId from the logs

    //     uint256[] memory evenRandomWord = new uint256[](1);
    //     evenRandomWord[0] = 2;

    //     VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWordsWithOverride(
    //         uint256(requestId),
    //         address(coinFlip),
    //         evenRandomWord
    //     );
    //     uint256 contractEndingBalance = address(coinFlip).balance;

    //     // Assert
    //     address[] memory recentWinners = coinFlip.getRecentWinners();
    //     CoinFlip.CoinFlipState coinFlipState = coinFlip.getCoinFlipState();
    //     uint256 endingTimeStamp = coinFlip.getLastTimeStamp();

    //     assertEq(recentWinners[0], coinFlip.getOwner());
    //     assertEq(recentWinners.length, 1);
    //     assert(uint256(coinFlipState) == 0);
    //     assertEq(contractStartingBalance, contractEndingBalance);
    //     assert(endingTimeStamp > startingTimeStamp);
    //     assertEq(address(PLAYER1).balance, STARTING_USER_BALANCE - minBet);
    //     assertEq(address(PLAYER2).balance, STARTING_USER_BALANCE - minBet);
    // }
}
