// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title TournamentMath
/// @notice Pure math functions for tournament calculations
library TournamentMath {
    /// @notice Calculate floor(log2(n)) for powers of 2
    /// @param n Must be a power of 2 and greater than 0
    /// @return Number of rounds needed for n participants
    function log2(uint256 n) internal pure returns (uint8) {
        require(n > 0 && isPowerOfTwo(n), "TournamentMath: n must be a power of 2");
        uint8 count = 0;
        while (n > 1) {
            n >>= 1;
            count++;
        }
        return count;
    }

    /// @notice Check if a number is a power of 2
    /// @param n The number to check
    /// @return True if n is a power of 2
    function isPowerOfTwo(uint256 n) internal pure returns (bool) {
        return n > 0 && (n & (n - 1)) == 0;
    }

    /// @notice Calculate the podium index for payout table
    /// @param totalRounds Total number of rounds in tournament
    /// @param eliminationRound Round when token was eliminated (1-based)
    /// @return Podium index for payout lookup (1=runner-up, 2=semi-finalist, etc)
    function calculatePodiumIndex(uint8 totalRounds, uint8 eliminationRound) internal pure returns (uint8) {
        require(eliminationRound > 0 && eliminationRound <= totalRounds, "TournamentMath: invalid round");
        return totalRounds - eliminationRound + 1;
    }

    /// @notice Calculate number of matches needed for a round
    /// @param participants Number of participants entering the round
    /// @return Number of matches needed
    function matchesInRound(uint256 participants) internal pure returns (uint256) {
        require(isPowerOfTwo(participants), "TournamentMath: participants must be power of 2");
        return participants / 2;
    }

    /// @notice Validate tournament size constraints
    /// @param entrants Number of entrants
    /// @param minEntrants Minimum allowed entrants
    /// @param maxEntrants Maximum allowed entrants
    /// @return True if valid tournament size
    function isValidTournamentSize(
        uint256 entrants,
        uint256 minEntrants,
        uint256 maxEntrants
    ) internal pure returns (bool) {
        return entrants >= minEntrants &&
               entrants <= maxEntrants &&
               isPowerOfTwo(entrants);
    }

    /// @notice Returns the smallest power of 2 >= n
    /// @param n Must be > 0
    function nextPowerOfTwo(uint256 n) internal pure returns (uint256) {
        if (isPowerOfTwo(n)) return n;
        uint256 p = 1;
        while (p < n) {
            p <<= 1;
        }
        return p;
    }
}