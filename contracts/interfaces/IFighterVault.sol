// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFighterVault {
    // Errors
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

    // Events
    event Deposit(uint256 indexed tokenId, address indexed depositor, uint256 assets, uint256 shares);
    event Withdraw(uint256 indexed tokenId, address indexed withdrawer, uint256 assets, uint256 shares);
    event VaultCreated(uint256 indexed tokenId, address indexed asset);
    event AssetsSeized(uint256 indexed tournamentId, uint256 indexed fromTokenId, uint256 indexed toTokenId, uint256 amount);

    // Core functions
    function register(
        uint256 tournamentId,
        string calldata _tokenURI,
        string calldata _name,
        string calldata _ticker,
        string calldata _description,
        address depositor
    ) external payable returns (uint256 tokenId);

    function refundRegistration(uint256 tokenId, uint256 entryFee, uint256 tournamentId) external;
    function sweepFees(uint256 tournamentId) external;
    function strikeActiveTournament(uint256 tokenId) external;

    function transferAssets(uint256 fromTokenId, uint256 toTokenId, uint256 amount) external;

    function mintFromMarket(
        uint256 tokenId,
        uint256 sharesToMint,
        uint256 assets,
        address receiver
    ) external payable;

    function redeem(uint256 tokenId, uint256 sharesToBurn) external returns (uint256 assets);
    function batchRedeem(uint256[] calldata tokenIds, uint256[] calldata sharesToBurn) external returns (uint256 totalAssets_);

    // View functions
    function activeTournament(uint256 tokenId) external view returns (uint256);
    function totalAssets(uint256 tokenId) external view returns (uint256);
    function totalSupply(uint256 tokenId) external view returns (uint256);
    function balanceOf(address account, uint256 tokenId) external view returns (uint256);
    function convertToShares(uint256 tokenId, uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 tokenId, uint256 shareAmount) external view returns (uint256);
    function uri(uint256 tokenId) external view returns (string memory);

    // Position tracking
    function getPositions(address user) external view returns (uint256[] memory);
    function getPositionCount(address user) external view returns (uint256);
}
