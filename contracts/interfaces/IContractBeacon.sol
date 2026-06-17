// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IContractBeacon {
    function fighterVault() external view returns (address);
    function matchEngine() external view returns (address);
    function tournamentManager() external view returns (address);
}
