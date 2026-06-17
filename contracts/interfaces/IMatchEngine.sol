// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMatchEngine {
    // Admin functions
    function setPaused(bool _paused) external;

    // Core functions
    function buyShares(
        uint256 tournamentId,
        uint256 tokenId,
        uint256 round,
        uint256 minShares,
        string calldata memo
    ) external payable;

    // View functions
    function getTrailingAssets(uint256 tokenId) external view returns (uint256);
    function getMatchTrailingAssets(uint256 tournamentId, uint256 round, uint256 battleIndex) external view returns (uint256, uint256);
    function getMatchTotalAssets(uint256 tournamentId, uint256 round, uint256 battleIndex) external view returns (uint256, uint256);
    function resetTrailing(uint256 tokenId) external;
}
