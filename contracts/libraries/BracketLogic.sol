// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title BracketLogic
 * @notice Pure mathematical and structural logic for single-elimination tournament brackets
 * @dev Uses XOR-based pairing for efficient opponent matching in bracket structures
 */
library BracketLogic {
    /**
     * @notice Calculate the opponent position for a given position in a specific round
     * @param position The current position in the bracket
     * @param round The round number (1-based)
     * @return opponentPosition The position of the opponent
     */
    function calculateOpponentPosition(uint16 position, uint256 round)
        internal
        pure
        returns (uint16 opponentPosition)
    {
        // XOR with the appropriate bit for the round to find opponent
        opponentPosition = position ^ uint16(1 << (round - 1));
    }

    /**
     * @notice Calculate the effective position for later rounds (where winners are stored)
     * @param position The original shuffled position
     * @param round The round number (1-based)
     * @return effectivePosition The effective position with lower bits masked
     */
    function calculateEffectivePosition(uint16 position, uint256 round)
        internal
        pure
        returns (uint16 effectivePosition)
    {
        // Mask off lower (round-1) bits to get the group base position
        // Round 2: mask = ~1 = 0xFFFE (mask off bit 0)
        // Round 3: mask = ~3 = 0xFFFC (mask off bits 0-1)
        uint16 mask = ~uint16((1 << (round - 1)) - 1);
        effectivePosition = position & mask;
    }

    /**
     * @notice Calculate both positions for a battle given round and battle index
     * @param round The round number (1-based)
     * @param battleIndex The battle index within the round (0-based)
     * @return positionA First participant position
     * @return positionB Second participant position
     */
    function calculateBattlePositions(uint256 round, uint256 battleIndex)
        internal
        pure
        returns (uint16 positionA, uint16 positionB)
    {
        uint16 groupSize = getGroupSizeForRound(round);
        positionA = uint16(battleIndex * groupSize);
        positionB = positionA ^ uint16(1 << (round - 1));
    }

    /**
     * @notice Calculate the base position for a battle
     * @param round The round number (1-based)
     * @param battleIndex The battle index within the round (0-based)
     * @return basePosition The base position for storing battle results
     */
    function calculateBattleBasePosition(uint256 round, uint256 battleIndex)
        internal
        pure
        returns (uint16 basePosition)
    {
        uint16 groupSize = getGroupSizeForRound(round);
        basePosition = uint16(battleIndex * groupSize);
    }

    /**
     * @notice Pack round and position into a storage key
     * @param round The round number
     * @param position The position within the bracket
     * @return key The packed storage key
     */
    function packRoundPositionKey(uint256 round, uint16 position)
        internal
        pure
        returns (uint256 key)
    {
        key = (round << 16) | position;
    }

    /**
     * @notice Unpack a storage key into round and position
     * @param key The packed storage key
     * @return round The round number
     * @return position The position within the bracket
     */
    function unpackRoundPositionKey(uint256 key)
        internal
        pure
        returns (uint256 round, uint16 position)
    {
        round = key >> 16;
        position = uint16(key & 0xFFFF);
    }

    /**
     * @notice Get the number of battles in a specific round
     * @param round The round number (1-based)
     * @param maxEntrants The maximum number of entrants in the tournament
     * @return battlesCount The number of battles in the round
     */
    function getBattlesInRound(uint256 round, uint16 maxEntrants)
        internal
        pure
        returns (uint256 battlesCount)
    {
        battlesCount = uint256(maxEntrants) >> round;
    }

    /**
     * @notice Get the group size for a specific round
     * @param round The round number (1-based)
     * @return groupSize The size of each group in the round
     */
    function getGroupSizeForRound(uint256 round)
        internal
        pure
        returns (uint16 groupSize)
    {
        groupSize = uint16(1 << round);
    }

    /**
     * @notice Get the mask for effective positions in a round
     * @param round The round number (1-based)
     * @return mask The bit mask for effective positions
     */
    function getEffectivePositionMask(uint256 round)
        internal
        pure
        returns (uint16 mask)
    {
        // Creates a mask that zeroes out the lower (round-1) bits
        // Round 1: mask = ~0 = 0xFFFF (no masking)
        // Round 2: mask = ~1 = 0xFFFE (mask off bit 0)
        // Round 3: mask = ~3 = 0xFFFC (mask off bits 0-1)
        mask = ~uint16((1 << (round - 1)) - 1);
    }

    /**
     * @notice Check if a battle index is valid for a given round
     * @param battleIndex The battle index to check
     * @param round The round number (1-based)
     * @param maxEntrants The maximum number of entrants
     * @return isValid True if the battle index is valid
     */
    function isValidBattleIndex(uint256 battleIndex, uint256 round, uint16 maxEntrants)
        internal
        pure
        returns (bool isValid)
    {
        uint256 battlesInRound = getBattlesInRound(round, maxEntrants);
        isValid = battleIndex < battlesInRound;
    }

    /**
     * @notice Check if a position is valid for the tournament size
     * @param position The position to check
     * @param maxEntrants The maximum number of entrants
     * @return isValid True if the position is valid
     */
    function isValidPosition(uint16 position, uint16 maxEntrants)
        internal
        pure
        returns (bool isValid)
    {
        isValid = position < maxEntrants;
    }

    /**
     * @notice Calculate which battle a position participates in for a given round
     * @param position The position in the bracket
     * @param round The round number (1-based)
     * @return battleIndex The battle index for this position in the round
     */
    function getBattleIndexForPosition(uint16 position, uint256 round)
        internal
        pure
        returns (uint256 battleIndex)
    {
        uint16 groupSize = getGroupSizeForRound(round);
        battleIndex = position / groupSize;
    }

    /**
     * @notice Calculate the XOR mask for finding opponents in a specific round
     * @param round The round number (1-based)
     * @return xorMask The XOR mask for opponent calculation
     */
    function getOpponentXorMask(uint256 round)
        internal
        pure
        returns (uint16 xorMask)
    {
        xorMask = uint16(1 << (round - 1));
    }

    /**
     * @notice Check if two positions are opponents in a given round
     * @param positionA First position
     * @param positionB Second position
     * @param round The round number (1-based)
     * @return isOpponent True if the positions face each other in this round
     */
    function areOpponents(uint16 positionA, uint16 positionB, uint256 round)
        internal
        pure
        returns (bool isOpponent)
    {
        uint16 xorResult = positionA ^ positionB;
        uint16 expectedXor = getOpponentXorMask(round);

        // They are opponents if:
        // 1. Their XOR equals exactly the expected mask for this round
        // 2. All other bits (higher and lower) are the same
        // This means they differ only in the specific bit for this round

        isOpponent = (xorResult == expectedXor);
    }

    /**
     * @notice Get the winner's storage position for the next round
     * @dev The winner advances to the same position but in the next round's bracket
     * @param currentPosition The current position of the winner
     * @param currentRound The current round number
     * @return nextRoundPosition The position where the winner should be stored for the next round
     */
    function getWinnerAdvancementPosition(uint16 currentPosition, uint256 currentRound)
        internal
        pure
        returns (uint16 nextRoundPosition)
    {
        // Winner maintains the same base position for the next round
        // Use the effective position (masked) as the storage position
        nextRoundPosition = calculateEffectivePosition(currentPosition, currentRound + 1);
    }
}