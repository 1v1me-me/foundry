//SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console } from "forge-std/Script.sol";
import "../contracts/ContractBeacon.sol";
import "../contracts/FighterVault.sol";
import "../contracts/TournamentManager.sol";
import "../contracts/MatchEngine.sol";

/**
 * @notice Stage 1: Deploy new implementation contracts for UUPS upgrades
 * @dev Deploys bare implementations (no proxies, no initialization).
 *      Writes addresses to deployments/implementations-{chainId}.json
 *      for consumption by UpgradeContracts.s.sol.
 *
 * Example:
 * make deploy-implementations RPC_URL=https://...
 */
contract DeployImplementations is Script {
    function run() external {
        vm.startBroadcast();

        address beaconImpl = address(new ContractBeacon());
        address fighterVaultImpl = address(new FighterVault());
        address matchEngineImpl = address(new MatchEngine());
        address tournamentManagerImpl = address(new TournamentManager());

        _exportImplementations(beaconImpl, fighterVaultImpl, matchEngineImpl, tournamentManagerImpl);

        vm.stopBroadcast();

        console.log("=== Implementation Addresses ===");
        console.log("ContractBeacon:", beaconImpl);
        console.log("FighterVault:", fighterVaultImpl);
        console.log("MatchEngine:", matchEngineImpl);
        console.log("TournamentManager:", tournamentManagerImpl);
    }

    function _exportImplementations(
        address beacon,
        address fighterVault,
        address matchEngine,
        address tournamentManager
    ) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(
            root,
            "/deployments/implementations-",
            vm.toString(block.chainid),
            ".json"
        );

        string memory jsonKey = "implementations";
        vm.serializeAddress(jsonKey, "ContractBeacon", beacon);
        vm.serializeAddress(jsonKey, "FighterVault", fighterVault);
        vm.serializeAddress(jsonKey, "MatchEngine", matchEngine);
        string memory json = vm.serializeAddress(jsonKey, "TournamentManager", tournamentManager);

        vm.writeJson(json, path);
    }
}
