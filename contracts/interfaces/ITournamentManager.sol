// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITournamentManager {
    // Enums
    enum TourStatus { Registering, Running, Finished, Cancelled }
    enum RoundState { Starting, Active, WaitingResults }

    // Events
    event Paused(address account);
    event Unpaused(address account);
    event TournamentCreated(
        uint256 indexed tournamentId,
        uint256 entryFee,
        uint256 roundDelay,
        uint256 roundDuration,
        uint256 startTime
    );
    event TournamentCancelled(uint256 indexed tournamentId);
    event TokenRegistered(uint256 indexed tournamentId, uint256 indexed tokenId, address indexed creator);
    event TournamentStarted(uint256 indexed tournamentId, uint256 randomSeed, uint256 roundStartTime);
    event BattleResolved(uint256 indexed tournamentId, uint256 round, uint256 battleIndex, uint256 winner);
    event TournamentFinished(uint256 indexed tournamentId, uint256 winner);
    event TournamentCreatorSet(address indexed account, bool allowed);

    // Core functions
    function createTournament(
        uint256 _entryFee,
        uint256 _roundDelay,
        uint256 _roundDuration,
        uint256 _startTime
    ) external returns (uint256 tournamentId);

    function startTournament(uint256 tournamentId) external;

    function register(
        uint256 tournamentId,
        string calldata tokenURI,
        string calldata name,
        string calldata ticker,
        string calldata description
    ) external payable returns (uint256 tokenId);

    function determineResult(
        uint256 tournamentId,
        uint256 round,
        uint256 battleIndex
    ) external returns (uint256 winner);

    function determineResults(uint256 tournamentId, uint256 round, uint256 startIndex, uint256 count) external;

    // View functions
    function getTokenAtPosition(uint256 tournamentId, uint16 shuffledPosition) external view returns (uint256);
    function getTokenPosition(uint256 tournamentId, uint256 tokenId) external view returns (uint16);
    function getOpponent(uint256 tournamentId, uint256 tokenId) external view returns (uint256 opponentTokenId);

    function getBattleParticipants(
        uint256 tournamentId,
        uint256 round,
        uint256 battleIndex
    ) external view returns (uint256 tokenA, uint256 tokenB);

    function getRoundState(uint256 tournamentId) external view returns (RoundState, uint256);
    function getChampion(uint256 tournamentId) external view returns (uint256);

    function tournaments(uint256 tournamentId) external view returns (
        uint16 entrantCount,
        uint16 currentRound,
        uint16 battlesCompleted,
        uint16 bracketSize,
        uint256 entryFee,
        uint256 randomSeed,
        uint256 roundStartTime,
        uint256 roundDelay,
        uint256 roundDuration,
        uint256 startTime,
        TourStatus status
    );

    function maxEntrants() external view returns (uint16);
    function setMaxEntrants(uint16 _maxEntrants) external;

    function canCreateTournament(address account) external view returns (bool);
    function setTournamentCreator(address account, bool allowed) external;

    function getTournamentTimings(uint256 tournamentId) external view returns (
        uint256 roundDelay,
        uint256 roundDuration,
        uint256 roundStartTime
    );

    function getShuffledBracket(uint256 tournamentId) external view returns (uint256[] memory bracket);

    function getAllWinners(uint256 tournamentId) external view returns (uint256[] memory);

    function roundSnapshots(uint256 tournamentId, uint256 tokenId, uint256 round) external view returns (uint128 totalAssets, uint128 trailingAssets);

    function treasury() external view returns (address);
    function platformFee() external view returns (uint256);
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
}
