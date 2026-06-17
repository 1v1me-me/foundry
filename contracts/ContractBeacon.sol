// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title ContractBeacon
 * @dev Central registry for contract addresses. All fighter contracts reference this beacon
 *      to look up sibling contract addresses.
 */
contract ContractBeacon is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address public fighterVault;
    address public matchEngine;
    address public tournamentManager;

    event AddressesUpdated(address fighterVault, address matchEngine, address tournamentManager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    /**
     * @dev Set all contract addresses at once
     * @param _fighterVault Address of the FighterVault contract
     * @param _matchEngine Address of the MatchEngine contract
     * @param _tournamentManager Address of the TournamentManager contract
     */
    function setAddresses(
        address _fighterVault,
        address _matchEngine,
        address _tournamentManager
    ) external onlyOwner {
        fighterVault = _fighterVault;
        matchEngine = _matchEngine;
        tournamentManager = _tournamentManager;
        emit AddressesUpdated(_fighterVault, _matchEngine, _tournamentManager);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[50] private __gap;
}
