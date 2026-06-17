// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IContractBeacon.sol";
import "./interfaces/ITournamentManager.sol";


/**
 * @title FighterVault
 * @dev Minimal vault implementation for fighter tokens
 * @notice Each token ID represents shares in its own vault with dedicated ETH assets
 */
contract FighterVault is Initializable, OwnableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Vault {
        uint256 totalAssets;
        uint256 totalShares;
        address creator;
        string tokenURI;
        string name;
        string ticker;
        string description;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public constant PRECISION = 1e18;

    // Core vault storage
    mapping(uint256 => Vault) public vaults;

    // User balances: user => tokenId => shares
    mapping(address => mapping(uint256 => uint256)) public shares;

    // Tournament participation tracking: tokenId => tournamentId
    // 0 = never participated, type(uint256).max = completed (redeemable), other = active in that tournament
    mapping(uint256 => uint256) public activeTournament;

    // Token ID generation
    uint256 private _tokenIdNonce;

    // Beacon reference
    IContractBeacon public beacon;

    // Position tracking: user => list of tokenIds they hold shares in
    mapping(address => uint256[]) private _userPositions;

    // Reverse index for O(1) removal: user => tokenId => (index + 1) in _userPositions
    // 0 means not present
    mapping(address => mapping(uint256 => uint256)) private _positionIndex;

    // Escrowed registration fees per tournament, swept to treasury on tournament start
    mapping(uint256 => uint256) public accruedFees;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        uint256 indexed tokenId,
        address indexed depositor,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        uint256 indexed tokenId,
        address indexed withdrawer,
        uint256 assets,
        uint256 shares
    );

    event VaultCreated(
        uint256 indexed tokenId,
        address indexed asset  // Always address(0) for ETH
    );

    event AssetsSeized(
        uint256 indexed tournamentId,
        uint256 indexed fromTokenId,
        uint256 indexed toTokenId,
        uint256 amount
    );

    event FeeCollected(
        uint256 indexed tournamentId,
        address indexed recipient,
        uint256 fee
    );

    event RegistrationRefunded(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error InsufficientShares();
    error InsufficientVaultAssets();
    error ZeroShares();
    error ZeroAssets();
    error InvalidETHAmount();
    error InvalidAddress();
    error TokenExists();
    error ETHTransferFailed();
    error DirectETHNotAllowed();
    error FighterStillActive();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _beacon, address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        beacon = IContractBeacon(_beacon);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyMatchEngine() {
        if (msg.sender != beacon.matchEngine()) revert NotAuthorized();
        _;
    }

    modifier onlyTournamentManager() {
        if (msg.sender != beacon.tournamentManager()) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                    TOURNAMENT MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Register a new fighter for a tournament
     * @param tournamentId The tournament ID to register for
     * @param _tokenURI The metadata URI for the token
     * @param _name The fighter name
     * @param _ticker The fighter ticker symbol
     * @param depositor Address to receive the shares (the registerer)
     * @return tokenId The generated token ID
     * @notice Only callable by TournamentManager during registration
     */
    function register(
        uint256 tournamentId,
        string calldata _tokenURI,
        string calldata _name,
        string calldata _ticker,
        string calldata _description,
        address depositor
    ) external payable onlyTournamentManager nonReentrant returns (uint256 tokenId) {
        if (msg.value == 0) revert ZeroAssets();

        tokenId = uint256(keccak256(abi.encodePacked(
            msg.sender,
            _tokenIdNonce++
        )));

        if (vaults[tokenId].creator != address(0)) revert TokenExists();

        // Set active tournament
        activeTournament[tokenId] = tournamentId;

        // Initialize vault with all fields
        Vault storage v = vaults[tokenId];
        v.creator = depositor;
        v.tokenURI = _tokenURI;
        v.name = _name;
        v.ticker = _ticker;
        v.description = _description;

        // Escrow fee, credit net amount to vault (1:1 shares)
        ITournamentManager tm = ITournamentManager(beacon.tournamentManager());
        uint256 fee = (msg.value * tm.platformFee()) / PRECISION;
        uint256 netAmount = msg.value - fee;

        accruedFees[tournamentId] += fee;

        v.totalAssets = netAmount;
        v.totalShares = netAmount;
        shares[depositor][tokenId] = netAmount;
        _addPosition(depositor, tokenId);

        emit VaultCreated(tokenId, address(0));
        emit Deposit(tokenId, depositor, netAmount, netAmount);
    }

    /**
     * @dev Refund a fighter's entry fee on tournament cancellation
     * @param tokenId The fighter token ID
     * @param entryFee The full entry fee amount to refund (net + escrowed fee)
     * @param tournamentId The tournament ID (to release escrowed fees)
     */
    function refundRegistration(uint256 tokenId, uint256 entryFee, uint256 tournamentId) external onlyTournamentManager nonReentrant {
        accruedFees[tournamentId] = 0;

        Vault storage v = vaults[tokenId];
        address creator = v.creator;

        v.totalAssets = 0;
        v.totalShares = 0;
        shares[creator][tokenId] = 0;
        _removePosition(creator, tokenId);
        activeTournament[tokenId] = type(uint256).max;

        (bool success, ) = payable(creator).call{value: entryFee}("");
        if (success) {
            emit RegistrationRefunded(tokenId, creator, entryFee);
        } else {
            ITournamentManager tm = ITournamentManager(beacon.tournamentManager());
            address treasuryAddr = tm.treasury();
            (bool sent, ) = payable(treasuryAddr).call{value: entryFee}("");
            sent;
            emit RegistrationRefunded(tokenId, treasuryAddr, entryFee);
        }
    }

    function sweepFees(uint256 tournamentId) external onlyTournamentManager {
        uint256 fees = accruedFees[tournamentId];
        if (fees == 0) return;
        accruedFees[tournamentId] = 0;
        ITournamentManager tm = ITournamentManager(beacon.tournamentManager());
        address treasuryAddr = tm.treasury();
        if (treasuryAddr != address(0)) {
            (bool sent, ) = treasuryAddr.call{value: fees}("");
            if (!sent) revert ETHTransferFailed();
            emit FeeCollected(tournamentId, treasuryAddr, fees);
        }
    }

    /**
     * @dev Mark fighter as completed tournament run (called on elimination or tournament end)
     * @param tokenId The fighter token ID
     */
    function strikeActiveTournament(uint256 tokenId) external onlyTournamentManager {
        activeTournament[tokenId] = type(uint256).max;
    }

    /**
     * @dev Transfer assets between vaults for prize distribution
     * @param fromTokenId Source vault token ID
     * @param toTokenId Destination vault token ID
     * @param amount Amount of ETH to transfer
     */
    function transferAssets(uint256 fromTokenId, uint256 toTokenId, uint256 amount)
        external
        onlyTournamentManager
        nonReentrant
    {
        Vault storage fromVault = vaults[fromTokenId];
        Vault storage toVault = vaults[toTokenId];

        if (fromVault.totalAssets < amount) revert InsufficientVaultAssets();

        fromVault.totalAssets -= amount;
        toVault.totalAssets += amount;

        emit AssetsSeized(activeTournament[fromTokenId], fromTokenId, toTokenId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        MINTING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Mint shares from MatchEngine without price calculation
     * @param tokenId The vault token ID
     * @param sharesToMint Amount of shares to mint (determined by LSLMSR)
     * @param assets Amount of ETH assets being deposited
     * @param receiver Address to receive the shares
     * @notice Only callable by MatchEngine, accepts ETH via msg.value
     */
    function mintFromMarket(
        uint256 tokenId,
        uint256 sharesToMint,
        uint256 assets,
        address receiver
    ) external payable onlyMatchEngine nonReentrant {
        if (assets == 0) revert ZeroAssets();
        if (sharesToMint == 0) revert ZeroShares();
        if (msg.value != assets) revert InvalidETHAmount();

        vaults[tokenId].totalAssets += assets;
        vaults[tokenId].totalShares += sharesToMint;
        if (shares[receiver][tokenId] == 0) {
            _addPosition(receiver, tokenId);
        }
        shares[receiver][tokenId] += sharesToMint;

        emit Deposit(tokenId, receiver, assets, sharesToMint);
    }

    /*//////////////////////////////////////////////////////////////
                        REDEMPTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Redeem shares for assets
     * @param tokenId The vault token ID
     * @param sharesToBurn Amount of shares to redeem
     * @return assets Amount of assets withdrawn
     */
    function redeem(
        uint256 tokenId,
        uint256 sharesToBurn
    ) public nonReentrant returns (uint256 assets) {
        if (sharesToBurn == 0) revert ZeroShares();

        // Fighter can only redeem after completing a tournament run
        if (activeTournament[tokenId] != type(uint256).max) {
            revert FighterStillActive();
        }

        uint256 userShares = shares[msg.sender][tokenId];
        if (userShares < sharesToBurn) revert InsufficientShares();

        Vault storage vault = vaults[tokenId];
        if (vault.totalShares == 0) revert ZeroShares();

        assets = convertToAssets(tokenId, sharesToBurn);

        vault.totalShares -= sharesToBurn;
        vault.totalAssets -= assets;
        shares[msg.sender][tokenId] -= sharesToBurn;
        if (shares[msg.sender][tokenId] == 0) {
            _removePosition(msg.sender, tokenId);
        }

        emit Withdraw(tokenId, msg.sender, assets, sharesToBurn);

        if (assets > 0) {
            (bool success, ) = payable(msg.sender).call{value: assets}("");
            if (!success) revert ETHTransferFailed();
        }
    }

    function batchRedeem(
        uint256[] calldata tokenIds,
        uint256[] calldata sharesToBurn
    ) external nonReentrant returns (uint256 totalAssets_) {
        require(tokenIds.length == sharesToBurn.length, "Length mismatch");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 burnAmount = sharesToBurn[i];
            if (burnAmount == 0) revert ZeroShares();
            if (activeTournament[tokenId] != type(uint256).max) revert FighterStillActive();

            uint256 userShares = shares[msg.sender][tokenId];
            if (userShares < burnAmount) revert InsufficientShares();

            Vault storage vault = vaults[tokenId];
            if (vault.totalShares == 0) revert ZeroShares();

            uint256 assets = convertToAssets(tokenId, burnAmount);

            vault.totalShares -= burnAmount;
            vault.totalAssets -= assets;
            shares[msg.sender][tokenId] -= burnAmount;
            if (shares[msg.sender][tokenId] == 0) {
                _removePosition(msg.sender, tokenId);
            }

            totalAssets_ += assets;

            emit Withdraw(tokenId, msg.sender, assets, burnAmount);
        }

        if (totalAssets_ > 0) {
            (bool success, ) = payable(msg.sender).call{value: totalAssets_}("");
            if (!success) revert ETHTransferFailed();
        }
    }


    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get total assets in a vault
     * @param tokenId The vault token ID
     * @return Total assets deposited in wei
     */
    function totalAssets(uint256 tokenId) public view returns (uint256) {
        return vaults[tokenId].totalAssets;
    }

    /**
     * @dev Get total shares for a vault (replaces totalSupply from ERC1155)
     * @param tokenId The vault token ID
     * @return Total shares outstanding
     */
    function totalSupply(uint256 tokenId) public view returns (uint256) {
        return vaults[tokenId].totalShares;
    }

    /**
     * @dev Get user's share balance
     * @param account The user address
     * @param tokenId The vault token ID
     * @return User's share balance
     */
    function balanceOf(address account, uint256 tokenId) public view returns (uint256) {
        return shares[account][tokenId];
    }

    /*//////////////////////////////////////////////////////////////
                    CONVERSION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Convert assets amount to shares
     * @param tokenId The vault token ID
     * @param assets Amount of assets to convert
     * @return shares Amount of shares
     */
    function convertToShares(uint256 tokenId, uint256 assets)
        public
        view
        returns (uint256)
    {
        Vault memory vault = vaults[tokenId];

        if (vault.totalAssets == 0 || vault.totalShares == 0) {
            return assets;
        }

        return (assets * vault.totalShares) / vault.totalAssets;
    }

    /**
     * @dev Convert shares amount to assets
     * @param tokenId The vault token ID
     * @param shareAmount Amount of shares to convert
     * @return assets Amount of assets
     */
    function convertToAssets(uint256 tokenId, uint256 shareAmount)
        public
        view
        returns (uint256)
    {
        Vault memory vault = vaults[tokenId];

        if (vault.totalShares == 0) {
            return 0;
        }

        return (shareAmount * vault.totalAssets) / vault.totalShares;
    }

    /**
     * @dev Returns the URI for a given token ID
     * @param tokenId The token ID to query
     * @return The URI string for the token
     */
    function uri(uint256 tokenId) public view returns (string memory) {
        return vaults[tokenId].tokenURI;
    }

    /**
     * @dev Get all tokenIds a user holds shares in
     * @param user The user address
     * @return tokenIds Array of tokenIds with nonzero shares
     */
    function getPositions(address user) external view returns (uint256[] memory) {
        return _userPositions[user];
    }

    /**
     * @dev Get the number of positions a user holds
     * @param user The user address
     * @return count Number of positions
     */
    function getPositionCount(address user) external view returns (uint256) {
        return _userPositions[user].length;
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION TRACKING (INTERNAL)
    //////////////////////////////////////////////////////////////*/

    function _addPosition(address user, uint256 tokenId) internal {
        if (_positionIndex[user][tokenId] != 0) return;
        _userPositions[user].push(tokenId);
        _positionIndex[user][tokenId] = _userPositions[user].length;
    }

    function _removePosition(address user, uint256 tokenId) internal {
        uint256 indexPlusOne = _positionIndex[user][tokenId];
        if (indexPlusOne == 0) return;

        uint256 lastIndex = _userPositions[user].length - 1;
        uint256 removeIndex = indexPlusOne - 1;

        if (removeIndex != lastIndex) {
            uint256 lastTokenId = _userPositions[user][lastIndex];
            _userPositions[user][removeIndex] = lastTokenId;
            _positionIndex[user][lastTokenId] = indexPlusOne;
        }

        _userPositions[user].pop();
        delete _positionIndex[user][tokenId];
    }

    /*//////////////////////////////////////////////////////////////
                    UPGRADE AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                    ETH HANDLING
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        revert DirectETHNotAllowed();
    }

    fallback() external payable {
        revert DirectETHNotAllowed();
    }

    /*//////////////////////////////////////////////////////////////
                    STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    uint256[50] private __gap;
}
