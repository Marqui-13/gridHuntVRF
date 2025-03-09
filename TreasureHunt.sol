// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";

/// @title TreasureHunt - A game where players guess the treasure's location on a 5x5 grid
/// @notice Uses Yul assembly for optimization and Chainlink VRF2 for randomness
contract TreasureHunt is VRFConsumerBaseV2 {
    // STATE VARIABLES
    address public owner;
    VRFCoordinatorV2Interface public vrfCoordinator;
    uint64 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 2; // For x and y coordinates
    mapping(address => uint256) public guesses; // Packed x, y coordinates
    mapping(uint256 => address) public requestIdToPlayer;

    // EVENTS
    event GuessSubmitted(address indexed player, uint256 x, uint256 y, uint256 amount);
    event TreasureRevealed(uint256 requestId, uint256 x, uint256 y);
    event TreasureFound(address indexed player, uint256 amount);

    // MODIFIERS
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    modifier onlyVRFCoordinator() {
        require(msg.sender == address(vrfCoordinator), "Only VRF Coordinator can call this");
        _;
    }

    // CONSTRUCTOR
    constructor(
        address _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        owner = msg.sender;
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
    }

    // SUBMIT GUESS FUNCTION
    /// @notice Submits a guess for the treasure's coordinates
    /// @param x X-coordinate (0-4)
    /// @param y Y-coordinate (0-4)
    function submitGuess(uint256 x, uint256 y) external payable {
        require(x <= 4 && y <= 4, "Coordinates must be 0-4");
        require(msg.value > 0, "Must send ETH to play");

        // Pack x and y into a single uint256 (x in bits 0-2, y in bits 3-5)
        uint256 packedGuess;
        assembly {
            packedGuess := or(shl(3, y), x)
            // Compute slot for guesses[msg.sender]
            mstore(0, caller())    // Store msg.sender at memory offset 0
            mstore(32, 8)          // Store base slot (8) at memory offset 32
            let slot := keccak256(0, 64) // Hash 64 bytes from memory offset 0
            sstore(slot, packedGuess)    // Store the packed guess at the correct slot
        }

        // Request random coordinates from Chainlink VRF
        uint256 requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        requestIdToPlayer[requestId] = msg.sender;

        emit GuessSubmitted(msg.sender, x, y, msg.value);
    }

    // FULFILL RANDOM WORDS CALLBACK
    /// @notice Callback function for Chainlink VRF to reveal the treasure's location
    /// @param requestId The ID of the VRF request
    /// @param randomWords Array containing random x and y coordinates
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override onlyVRFCoordinator {
        address player = requestIdToPlayer[requestId];
        require(player != address(0), "Invalid request ID");

        // Extract random x and y (0-4) from random words
        uint256 randomX = randomWords[0] % 5;
        uint256 randomY = randomWords[1] % 5;
        emit TreasureRevealed(requestId, randomX, randomY);

        // Retrieve player's guess using Yul
        uint256 packedGuess;
        assembly {
            // Compute slot for guesses[player]
            mstore(0, player)
            mstore(32, 8)
            let slot := keccak256(0, 64)
            packedGuess := sload(slot)
        }

        // Unpack player's x and y
        uint256 playerX;
        uint256 playerY;
        assembly {
            playerX := and(packedGuess, 0x7) // First 3 bits
            playerY := shr(3, and(packedGuess, 0x38)) // Next 3 bits
        }

        // Check if player won
        if (playerX == randomX && playerY == randomY) {
            uint256 prize = address(this).balance;
            assembly {
                let success := call(gas(), player, prize, 0, 0, 0, 0)
                if iszero(success) { revert(0, 0) }
            }
            emit TreasureFound(player, prize);
        }

        // Clear player's guess
        assembly {
            // Compute slot for guesses[player]
            mstore(0, player)
            mstore(32, 8)
            let slot := keccak256(0, 64)
            sstore(slot, 0)
        }
    }

    // RECEIVE FUNCTION
    receive() external payable {}
}