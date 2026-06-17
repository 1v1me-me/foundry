// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./libraries/TournamentMath.sol";
import "./libraries/FeistelShuffle.sol";
import "./libraries/BracketLogic.sol";
import "./interfaces/IContractBeacon.sol";
import "./interfaces/IFighterVault.sol";
import "./interfaces/IMatchEngine.sol";

/**
 * @title TournamentManager
 * @dev Uses format-preserving Feistel cipher for on-demand position shuffling without storage writes
 */
contract TournamentManager is Initializable, OwnableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    using BracketLogic for uint16;

    enum TourStatus {Registering, Running, Finished, Cancelled}
    enum RoundState {Starting, Active, WaitingResults}

    /// @dev Stored as uint128 via plain cast — values may truncate. Do not use for business logic.
    struct RoundSnapshot {
        uint128 totalAssets;
        uint128 trailingAssets;
    }

    struct Tournament {
        uint16 entrantCount;
        uint16 currentRound;        // (1-based)
        uint16 battlesCompleted;    // Battles completed in current round
        uint16 bracketSize;         // Next power of 2 >= entrantCount (set at tournament start)
        uint256 entryFee;
        uint256 randomSeed;
        uint256 roundStartTime;  // When current round starts/started (0 = not started)
        uint256 roundDelay;      // Delay in seconds between rounds
        uint256 roundDuration;   // Maximum duration in seconds for a round to be active
        uint256 startTime;       // Earliest time the tournament can be started
        TourStatus status;
        mapping(uint256 => uint256) roundWinners;      // packed: (round << 16) | position => winnerTokenId
    }

    mapping(uint256 => Tournament) public tournaments;
    mapping(uint256 => mapping(uint256 => bool)) public hasRegistered;
    mapping(uint256 => mapping(uint16 => uint256)) public entrantSlots; // Original registration order
    mapping(uint256 => mapping(uint256 => uint16)) public tokenToPosition; // Reverse mapping: token -> original position
    uint256 public nextTournamentId;

    IContractBeacon public beacon;

    uint256 public constant BYE_SENTINEL = 0xBA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1BA1B;

    // tournamentId => tokenId => round => snapshot (pre-transfer state at battle resolution)
    mapping(uint256 => mapping(uint256 => mapping(uint256 => RoundSnapshot))) public roundSnapshots;

    uint256 public constant PRECISION = 1e18;
    address public treasury;
    uint256 public platformFee;
    bool public paused;
    uint16 public maxEntrants;
    mapping(address => bool) public canCreateTournament;

    event TournamentCreated(uint256 indexed tournamentId, uint256 entryFee, uint256 roundDelay, uint256 roundDuration, uint256 startTime);
    event TournamentCancelled(uint256 indexed tournamentId);
    event Paused(address account);
    event Unpaused(address account);
    event TokenRegistered(uint256 indexed tournamentId, uint256 indexed tokenId, address indexed creator);
    event TournamentStarted(uint256 indexed tournamentId, uint256 randomSeed, uint256 roundStartTime);
    event BattleResolved(uint256 indexed tournamentId, uint256 round, uint256 battleIndex, uint256 winner);
    event TournamentFinished(uint256 indexed tournamentId, uint256 winner);
    event RoundCompleted(uint256 indexed tournamentId, uint256 round, uint256 nextRoundStartTime);
    event TournamentCreatorSet(address indexed account, bool allowed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _beacon,
        address _treasury,
        uint256 _platformFee,
        address initialOwner
    ) external initializer {
        require(_platformFee <= PRECISION, "Fee exceeds 100%");
        __Ownable_init(initialOwner);
        beacon = IContractBeacon(_beacon);
        treasury = _treasury;
        platformFee = _platformFee;
        nextTournamentId = 1;
        maxEntrants = 1024;
    }

    /**
     * @dev Sets the treasury address for platform fees
     * @param _treasury The address to receive platform fees
     */
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /**
     * @dev Sets the platform fee percentage (scaled by 1e18)
     * @param _fee Fee as a fraction of 1e18 (e.g., 0.0399e18 = 3.99%)
     */
    function setPlatformFee(uint256 _fee) external onlyOwner {
        require(_fee <= PRECISION, "Fee exceeds 100%");
        platformFee = _fee;
    }

    function setMaxEntrants(uint16 _maxEntrants) external onlyOwner {
        require(_maxEntrants > 1, "Invalid max entrants");
        maxEntrants = _maxEntrants;
    }

    function setTournamentCreator(address account, bool allowed) external onlyOwner {
        canCreateTournament[account] = allowed;
        emit TournamentCreatorSet(account, allowed);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Create a new tournament
     * @param _entryFee Fee to enter the tournament
     * @param _roundDelay Delay in seconds between rounds
     * @param _roundDuration Maximum duration in seconds for a round to be active
     * @param _startTime Earliest timestamp the tournament can be started
     */
    function createTournament(
        uint256 _entryFee,
        uint256 _roundDelay,
        uint256 _roundDuration,
        uint256 _startTime
    ) external returns (uint256 tournamentId) {
        require(canCreateTournament[msg.sender], "Not authorized");
        require(!paused, "Paused");
        require(_roundDelay >= 10 && _roundDelay <= 3600, "Invalid round delay (10s-1hr)");
        require(_roundDuration >= 30 && _roundDuration <= 86400, "Invalid round duration (30s-1day)");
        require(_entryFee > 0, "Invalid entry fee");

        tournamentId = nextTournamentId++;
        Tournament storage t = tournaments[tournamentId];
        t.entryFee = _entryFee;
        t.roundDelay = _roundDelay;
        t.roundDuration = _roundDuration;
        t.startTime = _startTime;

        emit TournamentCreated(tournamentId, _entryFee, _roundDelay, _roundDuration, _startTime);
    }

    /**
     * @notice Register for the tournament with a new fighter
     * @param tournamentId The tournament to register for
     * @param tokenURI The metadata URI for the fighter token
     * @param name The fighter name
     * @param ticker The fighter ticker symbol
     * @return tokenId The generated fighter token ID
     */
    function register(
        uint256 tournamentId,
        string calldata tokenURI,
        string calldata name,
        string calldata ticker,
        string calldata description
    ) external payable nonReentrant returns (uint256 tokenId) {
        Tournament storage t = tournaments[tournamentId];
        require(t.status == TourStatus.Registering, "Not in registration");
        require(t.entrantCount < maxEntrants, "Tournament full");
        require(block.timestamp < t.startTime, "Registration closed");
        require(msg.value == t.entryFee, "Wrong fee");

        tokenId = IFighterVault(beacon.fighterVault()).register{value: msg.value}(tournamentId, tokenURI, name, ticker, description, msg.sender);
        hasRegistered[tournamentId][tokenId] = true;
        uint16 position = t.entrantCount;
        entrantSlots[tournamentId][position] = tokenId;
        tokenToPosition[tournamentId][tokenId] = position;
        t.entrantCount++;

        emit TokenRegistered(tournamentId, tokenId, msg.sender);
    }

    /**
     * @notice Start a tournament after its start time has passed
     * @param tournamentId The tournament to start
     * @dev If fewer than 2 entrants, cancels the tournament and refunds any single entrant
     */
    function startTournament(uint256 tournamentId) external {
        Tournament storage t = tournaments[tournamentId];
        require(t.status == TourStatus.Registering, "Not in registration");
        require(block.timestamp >= t.startTime, "Too early");

        if (t.entrantCount < 2) {
            t.status = TourStatus.Cancelled;
            if (t.entrantCount == 1) {
                uint256 tokenId = entrantSlots[tournamentId][0];
                IFighterVault(beacon.fighterVault()).refundRegistration(tokenId, t.entryFee, tournamentId);
            }
            emit TournamentCancelled(tournamentId);
            return;
        }

        _startTournament(tournamentId, t);
    }

    function _startTournament(uint256 tournamentId, Tournament storage t) internal {
        IFighterVault(beacon.fighterVault()).sweepFees(tournamentId);
        t.randomSeed = uint256(keccak256(abi.encodePacked(block.prevrandao, tournamentId, block.timestamp)));
        t.bracketSize = uint16(TournamentMath.nextPowerOfTwo(t.entrantCount));
        t.battlesCompleted = t.bracketSize - t.entrantCount; // pre-count byes as resolved
        t.currentRound = 1;
        t.roundStartTime = block.timestamp + t.roundDelay;
        t.status = TourStatus.Running;
        emit TournamentStarted(tournamentId, t.randomSeed, t.roundStartTime);
    }

    // --- Bye helpers (O(1), pure) ---

    function _isByePosition(uint16 bracketSize, uint16 entrantCount, uint16 bracketPos)
        internal pure returns (bool)
    {
        uint16 numByes = bracketSize - entrantCount;
        return (bracketPos & 1 == 1) && (bracketPos >= bracketSize - 2 * numByes);
    }

    function _bracketPosToRank(uint16 bracketSize, uint16 entrantCount, uint16 bracketPos)
        internal pure returns (uint16)
    {
        uint16 zoneStart = 2 * entrantCount - bracketSize; // == bracketSize - 2*numByes
        if (bracketPos < zoneStart) return bracketPos;
        return zoneStart + (bracketPos - zoneStart) / 2;
    }

    function _rankToBracketPos(uint16 bracketSize, uint16 entrantCount, uint16 rank)
        internal pure returns (uint16)
    {
        uint16 zoneStart = 2 * entrantCount - bracketSize;
        if (rank < zoneStart) return rank;
        return zoneStart + (rank - zoneStart) * 2;
    }

    /**
     * @notice Get token at a shuffled position
     * @param tournamentId The tournament ID
     * @param shuffledPosition The shuffled position
     * @return tokenId The token at that position
     */
    function getTokenAtPosition(uint256 tournamentId, uint16 shuffledPosition)
        public
        view
        returns (uint256)
    {
        Tournament storage t = tournaments[tournamentId];
        require(shuffledPosition < t.bracketSize, "Invalid position");

        if (_isByePosition(t.bracketSize, t.entrantCount, shuffledPosition)) return BYE_SENTINEL;

        uint16 rank = _bracketPosToRank(t.bracketSize, t.entrantCount, shuffledPosition);
        uint16 originalPos = FeistelShuffle.unshuffleCycleWalk(rank, t.randomSeed, t.entrantCount, t.bracketSize);
        return entrantSlots[tournamentId][originalPos];
    }

    /**
     * @notice Get shuffled position for a token - O(1) complexity
     * @param tournamentId The tournament ID
     * @param tokenId The token ID
     * @return position The shuffled position
     */
    function getTokenPosition(uint256 tournamentId, uint256 tokenId)
        public
        view
        returns (uint16)
    {
        Tournament storage t = tournaments[tournamentId];
        require(hasRegistered[tournamentId][tokenId], "Token not registered");

        uint16 originalPosition = tokenToPosition[tournamentId][tokenId];
        uint16 rank = FeistelShuffle.shuffleCycleWalk(originalPosition, t.randomSeed, t.entrantCount, t.bracketSize);
        return _rankToBracketPos(t.bracketSize, t.entrantCount, rank);
    }

    /**
     * @notice Get participants of a battle
     * @param tournamentId The tournament ID
     * @param round The round number (1-based)
     * @param battleIndex The battle index within the round (0-based)
     * @return tokenA First participant
     * @return tokenB Second participant
     */
    function getBattleParticipants(uint256 tournamentId, uint256 round, uint256 battleIndex)
        public
        view
        returns (uint256 tokenA, uint256 tokenB)
    {
        Tournament storage t = tournaments[tournamentId];
        require(t.status != TourStatus.Registering, "Tournament not started");
        require(BracketLogic.isValidBattleIndex(battleIndex, round, t.bracketSize), "Invalid battle index");

        (uint16 positionA, uint16 positionB) = BracketLogic.calculateBattlePositions(round, battleIndex);
        tokenA = getTokenAtPosition(tournamentId, positionA);
        tokenB = getTokenAtPosition(tournamentId, positionB);

        if (round > 1) {
            uint256 winnerA = _getWinnerAtPosition(tournamentId, round - 1, positionA);
            if (winnerA != 0) tokenA = winnerA;

            uint256 winnerB = _getWinnerAtPosition(tournamentId, round - 1, positionB);
            if (winnerB != 0) tokenB = winnerB;
        }

        return (tokenA, tokenB);
    }

    /**
     * @notice Internal function to record a battle result
     * @param tournamentId The tournament ID
     * @param round The round number (1-based)
     * @param battleIndex The battle index within the round
     * @param battlePosition The battle's base position
     * @param winnerTokenId The winning token ID
     */
    /**
     * @notice Internal: determine and record a single battle result
     * @dev Accepts cached contract refs to avoid repeated beacon SLOADs in batch calls
     */
    function _determineResult(
        uint256 tournamentId,
        uint256 round,
        uint256 battleIndex,
        IMatchEngine me,
        IFighterVault fv
    ) internal returns (uint256 winner) {
        Tournament storage t = tournaments[tournamentId];

        (uint256 tokenA, uint256 tokenB) = getBattleParticipants(tournamentId, round, battleIndex);
        uint16 battlePosition = BracketLogic.calculateBattleBasePosition(round, battleIndex);
        uint256 key = BracketLogic.packRoundPositionKey(round, battlePosition);
        require(t.roundWinners[key] == 0, "Already resolved");

        uint256 trailingA = me.getTrailingAssets(tokenA);
        uint256 trailingB = me.getTrailingAssets(tokenB);
        if (trailingA != trailingB) {
            winner = trailingA > trailingB ? tokenA : tokenB;
        } else {
            bool coinFlip = uint256(keccak256(abi.encodePacked(t.randomSeed, round, battleIndex))) % 2 == 0;
            winner = coinFlip ? tokenA : tokenB;
        }
        uint256 loserTokenId = (winner == tokenA) ? tokenB : tokenA;

        // Record result
        t.roundWinners[key] = winner;
        t.battlesCompleted++;
        emit BattleResolved(tournamentId, round, battleIndex, winner);

        // Snapshot pre-transfer state for both fighters
        uint256 winnerAssets = fv.totalAssets(winner);
        uint256 loserAssets = fv.totalAssets(loserTokenId);
        roundSnapshots[tournamentId][winner][round] = RoundSnapshot(
            uint128(winnerAssets),
            uint128(trailingA >= trailingB ? trailingA : trailingB)
        );
        roundSnapshots[tournamentId][loserTokenId][round] = RoundSnapshot(
            uint128(loserAssets),
            uint128(trailingA >= trailingB ? trailingB : trailingA)
        );

        // Prize transfer — winner takes all
        if (loserAssets > 0) {
            fv.transferAssets(loserTokenId, winner, loserAssets);
        }

        me.resetTrailing(winner);
        fv.strikeActiveTournament(loserTokenId);

        // Check round completion
        {
            uint256 totalRounds = TournamentMath.log2(t.bracketSize);
            uint256 expectedBattles = uint256(t.bracketSize) >> t.currentRound;
            if (t.battlesCompleted == expectedBattles) {
                uint256 nextRoundStartTime = (round == totalRounds) ? 0 : block.timestamp + t.roundDelay;
                emit RoundCompleted(tournamentId, round, nextRoundStartTime);

                if (round == totalRounds) {
                    t.status = TourStatus.Finished;
                    fv.strikeActiveTournament(winner);
                    emit TournamentFinished(tournamentId, winner);
                } else {
                    t.currentRound++;
                    t.battlesCompleted = 0;
                    t.roundStartTime = block.timestamp + t.roundDelay;
                }
            }
        }
    }

    /**
     * @notice Automatically determine the result of a battle based on scorePrice
     * @param tournamentId The tournament ID
     * @param round The round number (1-based)
     * @param battleIndex The battle index within the round
     * @return winner The winning token ID
     */
    function determineResult(uint256 tournamentId, uint256 round, uint256 battleIndex)
        public
        returns (uint256 winner)
    {
        (RoundState state, uint256 currentRound) = getRoundState(tournamentId);
        require(round == currentRound, "Wrong round");
        require(state == RoundState.WaitingResults, "Round not waiting for results");

        // Prevent resolving bye battles
        if (round == 1) {
            Tournament storage t = tournaments[tournamentId];
            (, uint16 posB) = BracketLogic.calculateBattlePositions(round, battleIndex);
            require(!_isByePosition(t.bracketSize, t.entrantCount, posB), "Bye battle");
        }

        IMatchEngine me = IMatchEngine(beacon.matchEngine());
        IFighterVault fv = IFighterVault(beacon.fighterVault());
        return _determineResult(tournamentId, round, battleIndex, me, fv);
    }

    /**
     * @notice Determine undetermined battle results in a round (batched)
     * @param tournamentId The tournament ID
     * @param round The round number (1-based)
     * @param startIndex First battle index to process
     * @param count Maximum number of battles to process
     */
    function determineResults(uint256 tournamentId, uint256 round, uint256 startIndex, uint256 count) public {
        (RoundState state, uint256 currentRound) = getRoundState(tournamentId);
        require(round == currentRound, "Wrong round");
        require(state == RoundState.WaitingResults, "Round not waiting for results");

        Tournament storage t = tournaments[tournamentId];

        IMatchEngine me = IMatchEngine(beacon.matchEngine());
        IFighterVault fv = IFighterVault(beacon.fighterVault());

        uint256 expectedBattles = uint256(t.bracketSize) >> round;
        uint256 end = startIndex + count;
        if (end > expectedBattles) end = expectedBattles;

        for (uint256 battleIndex = startIndex; battleIndex < end; battleIndex++) {
            uint16 battlePosition = BracketLogic.calculateBattleBasePosition(round, battleIndex);
            uint256 key = BracketLogic.packRoundPositionKey(round, battlePosition);

            if (t.roundWinners[key] != 0) continue;

            // Skip bye battles in round 1
            if (round == 1) {
                (, uint16 posB) = BracketLogic.calculateBattlePositions(round, battleIndex);
                if (_isByePosition(t.bracketSize, t.entrantCount, posB)) continue;
            }

            _determineResult(tournamentId, round, battleIndex, me, fv);
        }
    }

    /**
     * @notice Get winner at a specific position in a round
     * @param tournamentId The tournament ID
     * @param round The round number
     * @param position The position to check
     * @return winner The winner token ID (0 if no winner yet)
     */
    function _getWinnerAtPosition(uint256 tournamentId, uint256 round, uint16 position)
        internal
        view
        returns (uint256)
    {
        Tournament storage t = tournaments[tournamentId];
        uint256 key = BracketLogic.packRoundPositionKey(round, position);
        uint256 winner = t.roundWinners[key];
        if (winner != 0) return winner;

        // Round 1 bye auto-advance: if the odd partner is a bye, the even position's fighter wins
        if (round == 1 && _isByePosition(t.bracketSize, t.entrantCount, position | 1)) {
            return getTokenAtPosition(tournamentId, uint16(position & ~uint16(1)));
        }

        return 0;
    }

    /**
     * @notice Get the current state of the tournament round
     * @param tournamentId The tournament ID
     * @return state The current round state
     */
    function getRoundState(uint256 tournamentId) public view returns (RoundState, uint256) {
        Tournament storage t = tournaments[tournamentId];
        require(t.status == TourStatus.Running && t.roundStartTime != 0, "Not running");

        if (block.timestamp < t.roundStartTime) {
            return (RoundState.Starting, t.currentRound);
        }

        uint256 elapsed = block.timestamp - t.roundStartTime;
        uint256 expectedBattles = uint256(t.bracketSize) >> t.currentRound;

        if (t.battlesCompleted < expectedBattles && elapsed < t.roundDuration) return (RoundState.Active, t.currentRound);
        if (t.battlesCompleted < expectedBattles) return (RoundState.WaitingResults, t.currentRound);

        return (RoundState.WaitingResults, t.currentRound);
    }

    /**
     * @notice Get the champion (winner) of a finished tournament
     * @param tournamentId The tournament ID
     * @return The champion token ID (0 if tournament not finished)
     */
    function getChampion(uint256 tournamentId) public view returns (uint256) {
        Tournament storage t = tournaments[tournamentId];
        if (t.status != TourStatus.Finished) return 0;

        uint8 totalRounds = TournamentMath.log2(t.bracketSize);
        uint256 key = BracketLogic.packRoundPositionKey(totalRounds, 0);
        return t.roundWinners[key];
    }

    /**
     * @notice Get all battle winners for a tournament
     * @param tournamentId The tournament ID
     * @return winners Array of winner token IDs (0 = not yet resolved), ordered by round then battle index
     */
    function getAllWinners(uint256 tournamentId)
        external view returns (uint256[] memory winners)
    {
        Tournament storage t = tournaments[tournamentId];
        if (t.status == TourStatus.Registering) return new uint256[](0);

        uint256 totalBattles = t.bracketSize - 1;
        winners = new uint256[](totalBattles);

        uint256 idx = 0;
        uint8 totalRounds = TournamentMath.log2(t.bracketSize);
        for (uint256 round = 1; round <= totalRounds; round++) {
            uint256 battlesInRound = t.bracketSize >> round;
            for (uint256 battle = 0; battle < battlesInRound; battle++) {
                uint16 pos = BracketLogic.calculateBattleBasePosition(round, battle);
                if (round == 1) {
                    winners[idx++] = _getWinnerAtPosition(tournamentId, round, pos);
                } else {
                    winners[idx++] = t.roundWinners[BracketLogic.packRoundPositionKey(round, pos)];
                }
            }
        }
    }

    /**
     * @notice Get tournament timing parameters
     * @param tournamentId The tournament ID
     * @return roundDelay Delay in seconds between rounds
     * @return roundDuration Maximum duration in seconds for a round to be active
     */
    function getTournamentTimings(uint256 tournamentId)
        external
        view
        returns (uint256 roundDelay, uint256 roundDuration, uint256 roundStartTime)
    {
        Tournament storage t = tournaments[tournamentId];
        return (t.roundDelay, t.roundDuration, t.roundStartTime);
    }

    /**
     * @notice Get the shuffled bracket for a tournament
     * @param tournamentId The tournament ID
     * @return bracket Array of token IDs in shuffled order
     */
    function getShuffledBracket(uint256 tournamentId)
        external
        view
        returns (uint256[] memory bracket)
    {
        Tournament storage t = tournaments[tournamentId];
        require(t.status != TourStatus.Registering, "Tournament not started");

        bracket = new uint256[](t.bracketSize);
        for (uint16 i = 0; i < t.bracketSize; i++) {
            bracket[i] = getTokenAtPosition(tournamentId, i);
        }
        return bracket;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[50] private __gap;
}
