// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IContractBeacon.sol";
import "./interfaces/IFighterVault.sol";
import "./interfaces/ITournamentManager.sol";

contract MatchEngine is Initializable, OwnableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    IContractBeacon public beacon;

    uint256 public constant PRECISION = 1e18;

    uint256 public tau;

    mapping(uint256 => uint256) public trailingAssets;    // tokenId => trailing totalAssets
    mapping(uint256 => uint256) public lastAssetUpdate;   // tokenId => timestamp of last update

    event SharesBought(
        uint256 indexed tournamentId,
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 round,
        uint256 ethAmount,
        uint256 sharesReceived,
        string memo
    );

    event FeeCollected(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 fee
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _beacon, address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        beacon = IContractBeacon(_beacon);
        tau = 12;
    }

    function setTau(uint256 _tau) external onlyOwner {
        tau = _tau;
    }

    function buyShares(
        uint256 tournamentId,
        uint256 tokenId,
        uint256 round,
        uint256 minShares,
        string calldata memo
    ) external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");
        ITournamentManager tm = ITournamentManager(beacon.tournamentManager());
        (ITournamentManager.RoundState state, uint256 currentRound) = tm.getRoundState(tournamentId);
        require(state == ITournamentManager.RoundState.Active, "Round not active");
        require(round == currentRound, "Wrong round");

        IFighterVault fv = IFighterVault(beacon.fighterVault());
        require(fv.activeTournament(tokenId) == tournamentId, "Token not in tournament");

        trailingAssets[tokenId] = getTrailingAssets(tokenId);
        lastAssetUpdate[tokenId] = block.timestamp;

        uint256 fee = (msg.value * tm.platformFee()) / PRECISION;
        uint256 netAmount = msg.value - fee;

        if (fee > 0) {
            address treasuryAddr = tm.treasury();
            if (treasuryAddr != address(0)) {
                (bool sent, ) = treasuryAddr.call{value: fee}("");
                require(sent, "Fee transfer failed");
                emit FeeCollected(tokenId, msg.sender, fee);
            } else {
                netAmount = msg.value;
            }
        }

        uint256 sharesOut = fv.convertToShares(tokenId, netAmount);
        require(sharesOut >= minShares, "Exceeds slippage");

        fv.mintFromMarket{value: netAmount}(tokenId, sharesOut, netAmount, msg.sender);
        emit SharesBought(tournamentId, tokenId, msg.sender, round, msg.value, sharesOut, memo);
    }

    function getTrailingAssets(uint256 tokenId) public view returns (uint256) {
        uint256 currentAssets = IFighterVault(beacon.fighterVault()).totalAssets(tokenId);

        if (lastAssetUpdate[tokenId] == 0) {
            return currentAssets;
        }

        uint256 roundEnd = _roundEnd(tokenId);
        uint256 evalTime = (roundEnd != 0 && block.timestamp > roundEnd) ? roundEnd : block.timestamp;
        uint256 elapsed = evalTime - lastAssetUpdate[tokenId];
        if (elapsed >= tau) {
            return currentAssets;
        }

        uint256 baseAssets = trailingAssets[tokenId];
        if (currentAssets >= baseAssets) {
            return baseAssets + ((currentAssets - baseAssets) * elapsed) / tau;
        } else {
            return baseAssets - ((baseAssets - currentAssets) * elapsed) / tau;
        }
    }

    function _roundEnd(uint256 tokenId) internal view returns (uint256) {
        uint256 tournamentId = IFighterVault(beacon.fighterVault()).activeTournament(tokenId);
        if (tournamentId == 0) return 0;
        (, uint256 roundDuration, uint256 roundStartTime) =
            ITournamentManager(beacon.tournamentManager()).getTournamentTimings(tournamentId);
        return roundStartTime + roundDuration;
    }

    function getMatchTrailingAssets(uint256 tournamentId, uint256 round, uint256 battleIndex) external view returns (uint256, uint256) {
        (uint256 tokenA, uint256 tokenB) = ITournamentManager(beacon.tournamentManager()).getBattleParticipants(tournamentId, round, battleIndex);
        return (getTrailingAssets(tokenA), getTrailingAssets(tokenB));
    }

    function getMatchTotalAssets(uint256 tournamentId, uint256 round, uint256 battleIndex) external view returns (uint256, uint256) {
        ITournamentManager tm = ITournamentManager(beacon.tournamentManager());
        IFighterVault fv = IFighterVault(beacon.fighterVault());
        (uint256 tokenA, uint256 tokenB) = tm.getBattleParticipants(tournamentId, round, battleIndex);
        return (fv.totalAssets(tokenA), fv.totalAssets(tokenB));
    }

    function resetTrailing(uint256 tokenId) external {
        require(msg.sender == beacon.tournamentManager(), "Only TournamentManager");
        trailingAssets[tokenId] = IFighterVault(beacon.fighterVault()).totalAssets(tokenId);
        lastAssetUpdate[tokenId] = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[50] private __gap;
}
