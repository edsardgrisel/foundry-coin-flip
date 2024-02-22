// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract CoinFlip is VRFConsumerBaseV2 {
    //Errors
    error CoinFlip___NotEnoughEthSent();
    error CoinFlip__CoinFlipNotOpen();
    error CoinFlip__TransferFailed();
    error CoinFlip__RaffleNotOpen();
    error CoinFlip__UpkeepNotNeeded(uint256 numPlayers, uint256 raffleState);
    error CoinFlip__InsufficientContractBalance();
    error CoinFlip__NonOwnerCantCallFund();
    error CoinFlip__TooMuchEthSent();
    error CoinFlip__NotSignedUp();

    //Enums
    enum CoinFlipState {
        OPEN,
        CALCULATING
    }

    //Constant variables
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    //Immutable variables
    uint256 private immutable i_minBet;
    uint256 private immutable i_interval;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    VRFCoordinatorV2Interface private i_vrfCoordinator;
    address private immutable i_owner;
    uint256 private immutable i_maxBet;

    //State variables
    uint256 private s_lastTimeStamp;
    address[] private s_players;
    address payable[] private s_betters;
    mapping(address => uint256) private s_addressToAmountBet;
    CoinFlipState private s_coinFlipState;
    address[] private s_recentWinners;

    //Events
    event SignedUpToCoinFlip(address indexed player);
    event RequestedCoinFlipWinner(uint256 indexed requestId);
    event WinnerPicked(address payable[] indexed winner);

    modifier onlyOwner() {
        if (i_owner != msg.sender) {
            revert CoinFlip__NonOwnerCantCallFund();
        }
        _;
    }

    modifier onlySignedUpAddresses() {
        bool isSignedUp = false;
        for (uint256 i = 0; i < s_players.length; i++) {
            if (s_players[i] == msg.sender) {
                isSignedUp = true;
                continue;
            }
        }
        if (!isSignedUp) {
            revert CoinFlip__NotSignedUp();
        }
        _;
    }

    constructor(
        uint256 minBet,
        uint256 maxBet,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2(vrfCoordinator) {
        i_minBet = minBet;
        i_maxBet = maxBet;
        i_interval = interval;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinator);
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        i_owner = msg.sender;

        s_lastTimeStamp = block.timestamp;
        s_coinFlipState = CoinFlipState.OPEN;
    }

    /**
     * Registers a user to the contract to be able to place bets
     */
    function signUpToCoinFlip() public {
        s_players.push(msg.sender);
        emit SignedUpToCoinFlip(msg.sender);
    }

    function fund() public payable onlyOwner {}

    function bet() public payable onlySignedUpAddresses {
        if (msg.value < i_minBet) {
            revert CoinFlip___NotEnoughEthSent();
        }
        if (msg.value > i_maxBet) {
            revert CoinFlip__TooMuchEthSent();
        }
        if (s_coinFlipState != CoinFlipState.OPEN) {
            revert CoinFlip__CoinFlipNotOpen();
        }
        s_addressToAmountBet[msg.sender] += msg.value;
        s_betters.push(payable(msg.sender));
    }

    function checkUpkeep(
        bytes memory /* checkData */
    ) public view returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) > i_interval;
        bool isOpen = CoinFlipState.OPEN == s_coinFlipState;
        uint256 totalBet;
        for (uint256 i = 0; i < s_betters.length; i++) {
            totalBet += s_addressToAmountBet[s_betters[i]];
        }
        bool hasSufficientBalance = address(this).balance >= 4 * totalBet;
        /* 2*totalBet is sufficient when no fees are considered but to avoid this problem with fees
         4*totalBet is chosen to avoid a CoinFlip__TransferFailed because the contract cant payout winnings */
        if (!hasSufficientBalance)
            revert CoinFlip__InsufficientContractBalance(); // Ideally this should trigger all bets to be refunded
        bool hasBetters = s_betters.length > 0;
        upkeepNeeded = timeHasPassed && isOpen && hasBetters;
        return (upkeepNeeded, "0x0");
    }

    function performUpkeep(bytes calldata /* performData */) external {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert CoinFlip__UpkeepNotNeeded(
                s_betters.length,
                uint256(s_coinFlipState)
            );
        }
        s_coinFlipState = CoinFlipState.CALCULATING;
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            NUM_WORDS
        );
        emit RequestedCoinFlipWinner(requestId);
    }

    function fulfillRandomWords(
        uint256,
        uint256[] memory randomWords
    ) internal override {
        bool houseWin = randomWords[0] % 2 == 0;
        address payable[] memory winners;
        if (houseWin) {
            winners[0] = payable(address(this));
        } else {
            winners = s_betters;
        }
        s_recentWinners = winners;
        s_coinFlipState = CoinFlipState.OPEN;

        s_betters = new address payable[](0);
        s_lastTimeStamp = block.timestamp;

        //if house won, skip payout
        if (!houseWin) {
            //if house lost, payout to betters
            for (uint256 i = 0; i < s_recentWinners.length; i++) {
                //mapping(address => uint256) private s_addressToAmountBet;
                address winner = s_recentWinners[i];
                uint256 amountBet = s_addressToAmountBet[winner];
                (bool success, ) = winner.call{value: 2 * amountBet}("");
                if (!success) {
                    revert CoinFlip__TransferFailed();
                }
            }
        }
        emit WinnerPicked(winners);
    }

    function getCoinFlipState() external view returns (CoinFlipState) {
        return s_coinFlipState;
    }

    function getPlayerAtIndex(uint256 i) external view returns (address) {
        return s_players[i];
    }

    function getOwner() external view returns (address) {
        return i_owner;
    }

    function getBetterAtIndex(uint256 i) external view returns (address) {
        return s_betters[i];
    }

    function getBettersBetAmount(
        address better
    ) external view returns (uint256) {
        return s_addressToAmountBet[better];
    }

    function getPlayersLength() external view returns (uint256) {
        return s_players.length;
    }

    function getRecentWinners() external view returns (address[] memory) {
        return s_recentWinners;
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }
}
