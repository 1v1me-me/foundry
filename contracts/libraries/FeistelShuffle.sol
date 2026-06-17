// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title FeistelShuffle
 * @notice Library for efficient O(1) position shuffling using Feistel networks
 * @dev Implements a 4-round Feistel network for format-preserving encryption
 *      Supports both balanced (even bits) and unbalanced (odd bits) cases
 *      All functions are gas-efficient pure operations with no storage
 */
library FeistelShuffle {
    /**
     * @notice Shuffles a position using a Feistel network
     * @param position Original position to shuffle
     * @param seed Random seed for shuffling
     * @param maxEntrants Maximum number of entrants (must be power of 2)
     * @return Shuffled position within [0, maxEntrants)
     */
    function shuffle(uint16 position, uint256 seed, uint16 maxEntrants)
        internal
        pure
        returns (uint16)
    {
        require(maxEntrants & (maxEntrants - 1) == 0, "Must be power of 2");
        require(position < maxEntrants, "Position out of bounds");

        uint8 bits = uint8(log2(maxEntrants));
        uint16 L;
        uint16 R;

        // For balanced case (even bits)
        if (bits % 2 == 0) {
            uint8 halfBits = bits / 2;
            uint16 mask = uint16((1 << halfBits) - 1);

            L = position >> halfBits;
            R = position & mask;

            for (uint8 round = 0; round < 4; round++) {
                uint16 temp = L;
                L = R;
                R = temp ^ (roundFunction(R, round, seed) & mask);
            }

            return (L << halfBits) | R;
        }

        // Unbalanced case (odd bits)
        uint8 largeBits = (bits + 1) / 2;
        uint8 smallBits = bits / 2;

        L = position >> smallBits;
        R = position & uint16((1 << smallBits) - 1);

        // Track current sizes
        uint8 currentLeftBits = largeBits;
        uint8 currentRightBits = smallBits;

        for (uint8 round = 0; round < 4; round++) {
            uint16 temp = L;
            L = R;

            // Mask matches the size of temp (old L)
            R = temp ^ (roundFunction(R, round, seed) & uint16((1 << currentLeftBits) - 1));

            // Swap the bit counts
            (currentLeftBits, currentRightBits) = (currentRightBits, currentLeftBits);
        }

        // After even number of rounds, sizes are back to original
        return (L << smallBits) | R;
    }

    /**
     * @notice Inverse Feistel transformation - unshuffles a position
     * @dev Runs the same Feistel structure in reverse order (rounds 3,2,1,0)
     * @param shuffledPosition Shuffled position to restore
     * @param seed Random seed used for shuffling (must match shuffle seed)
     * @param maxEntrants Maximum number of entrants (must be power of 2)
     * @return Original position before shuffling
     */
    function unshuffle(uint16 shuffledPosition, uint256 seed, uint16 maxEntrants)
        internal
        pure
        returns (uint16)
    {
        require(maxEntrants & (maxEntrants - 1) == 0, "Must be power of 2");
        require(shuffledPosition < maxEntrants, "Position out of bounds");

        uint8 bits = uint8(log2(maxEntrants));
        uint16 L;
        uint16 R;

        // For balanced case (even bits)
        if (bits % 2 == 0) {
            uint8 halfBits = bits / 2;
            uint16 mask = uint16((1 << halfBits) - 1);

            L = shuffledPosition >> halfBits;
            R = shuffledPosition & mask;

            // Run rounds in reverse: 3, 2, 1, 0
            for (uint8 i = 0; i < 4; i++) {
                uint8 round = 3 - i;
                uint16 temp = R;
                R = L;
                L = temp ^ (roundFunction(L, round, seed) & mask);
            }

            return (L << halfBits) | R;
        }

        // Unbalanced case (odd bits)
        uint8 largeBits = (bits + 1) / 2;
        uint8 smallBits = bits / 2;

        // After 4 (even) rounds, sizes are back to original
        // So we start with same split as forward function
        L = shuffledPosition >> smallBits;
        R = shuffledPosition & uint16((1 << smallBits) - 1);

        // After 4 forward rounds: L has largeBits, R has smallBits (back to start)
        // So for reverse, we start with those same sizes
        uint8 currentLeftBits = largeBits;
        uint8 currentRightBits = smallBits;

        // Run rounds in reverse: 3, 2, 1, 0
        for (uint8 i = 0; i < 4; i++) {
            uint16 temp = R;
            R = L;

            L = temp ^ (roundFunction(L, uint8(3 - i), seed) & uint16((1 << currentRightBits) - 1));

            (currentLeftBits, currentRightBits) = (currentRightBits, currentLeftBits);
        }

        return (L << smallBits) | R;
    }

    /**
     * @notice The round function for Feistel network
     * @dev Uses keccak256 hash for pseudo-randomness
     * @param input Input value for the round function
     * @param round Current round number (0-3)
     * @param seed Random seed for deterministic pseudo-randomness
     * @return Pseudo-random output based on input, round, and seed
     */
    function roundFunction(uint16 input, uint8 round, uint256 seed)
        internal
        pure
        returns (uint16)
    {
        return uint16(uint256(keccak256(abi.encodePacked(input, round, seed))) >> 240);
    }

    /**
     * @notice Cycle-walking shuffle for non-power-of-2 domains
     * @dev Shuffles over shuffleSize (power of 2), retries until result < domainSize.
     *      Terminates because domainSize > shuffleSize/2 (nextPowerOfTwo property).
     * @param position Original position in [0, domainSize)
     * @param seed Random seed
     * @param domainSize Actual number of elements (may not be power of 2)
     * @param shuffleSize Next power of 2 >= domainSize
     * @return Shuffled position in [0, domainSize)
     */
    function shuffleCycleWalk(uint16 position, uint256 seed, uint16 domainSize, uint16 shuffleSize)
        internal
        pure
        returns (uint16)
    {
        require(position < domainSize, "Position out of bounds");
        uint16 result = shuffle(position, seed, shuffleSize);
        while (result >= domainSize) {
            result = shuffle(result, seed, shuffleSize);
        }
        return result;
    }

    /**
     * @notice Cycle-walking unshuffle for non-power-of-2 domains
     * @param shuffledPosition Shuffled position in [0, domainSize)
     * @param seed Random seed (must match shuffleCycleWalk)
     * @param domainSize Actual number of elements
     * @param shuffleSize Next power of 2 >= domainSize
     * @return Original position in [0, domainSize)
     */
    function unshuffleCycleWalk(uint16 shuffledPosition, uint256 seed, uint16 domainSize, uint16 shuffleSize)
        internal
        pure
        returns (uint16)
    {
        require(shuffledPosition < domainSize, "Position out of bounds");
        uint16 result = unshuffle(shuffledPosition, seed, shuffleSize);
        while (result >= domainSize) {
            result = unshuffle(result, seed, shuffleSize);
        }
        return result;
    }

    /**
     * @notice Calculate log base 2 of a number
     * @dev Used to determine bit count for Feistel network setup
     * @param n Number to calculate log2 of
     * @return The log base 2 of n
     */
    function log2(uint256 n) internal pure returns (uint256) {
        uint256 log = 0;
        while (n > 1) {
            n = n >> 1;
            log++;
        }
        return log;
    }
}