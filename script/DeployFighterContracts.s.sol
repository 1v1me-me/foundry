//SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./DeployHelpers.s.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../contracts/ContractBeacon.sol";
import "../contracts/FighterVault.sol";
import "../contracts/TournamentManager.sol";
import "../contracts/MatchEngine.sol";

/**
 * @notice Deploy script for ContractBeacon, FighterVault, TournamentManager, and MatchEngine
 * @dev Deploys implementations and ERC1967 proxies directly (no factory contract on-chain)
 *
 * Example:
 * yarn deploy --file DeployFighterContracts.s.sol  # local anvil chain
 * yarn deploy --file DeployFighterContracts.s.sol --network sepolia # live network
 */
contract DeployFighterContracts is ScaffoldETHDeploy {
    // Platform fee: 3.99% = 0.0399 * 1e18
    uint256 constant PLATFORM_FEE = 0.0399e18;

    function run() external ScaffoldEthDeployerRunner {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address keeper = vm.envAddress("KEEPER_ADDRESS");

        // Deploy implementations
        address beaconImpl = address(new ContractBeacon());
        address fighterVaultImpl = address(new FighterVault());
        address matchEngineImpl = address(new MatchEngine());
        address tournamentManagerImpl = address(new TournamentManager());

        // Deploy proxies — deployer temporarily owns beacon to call setAddresses
        address beacon = address(new ERC1967Proxy(
            beaconImpl,
            abi.encodeCall(ContractBeacon.initialize, (deployer))
        ));

        address fighterVault = address(new ERC1967Proxy(
            fighterVaultImpl,
            abi.encodeCall(FighterVault.initialize, (beacon, admin))
        ));

        address matchEngine = address(new ERC1967Proxy(
            matchEngineImpl,
            abi.encodeCall(MatchEngine.initialize, (beacon, admin))
        ));

        address tournamentManager = address(new ERC1967Proxy(
            tournamentManagerImpl,
            abi.encodeCall(TournamentManager.initialize, (beacon, treasury, PLATFORM_FEE, deployer))
        ));

        // Wire up beacon and transfer ownership to admin
        ContractBeacon(beacon).setAddresses(fighterVault, matchEngine, tournamentManager);
        OwnableUpgradeable(beacon).transferOwnership(admin);

        // Grant the keeper permission to create tournaments, then hand the manager to admin
        TournamentManager(tournamentManager).setTournamentCreator(keeper, true);
        OwnableUpgradeable(tournamentManager).transferOwnership(admin);

        // Record proxy addresses for scaffold-eth
        deployments.push(Deployment("ContractBeacon", beacon));
        deployments.push(Deployment("FighterVault", fighterVault));
        deployments.push(Deployment("TournamentManager", tournamentManager));
        deployments.push(Deployment("MatchEngine", matchEngine));

        console.log("=== Proxy Addresses ===");
        console.log("ContractBeacon:", beacon);
        console.log("FighterVault:", fighterVault);
        console.log("TournamentManager:", tournamentManager);
        console.log("MatchEngine:", matchEngine);
        console.log("=== Implementation Addresses ===");
        console.log("ContractBeacon impl:", beaconImpl);
        console.log("FighterVault impl:", fighterVaultImpl);
        console.log("TournamentManager impl:", tournamentManagerImpl);
        console.log("MatchEngine impl:", matchEngineImpl);
        console.log("=== Ownership ===");
        console.log("Admin (owner):", admin);
        console.log("Treasury:", treasury);
        console.log("Keeper (tournament creator):", keeper);
    }
}
