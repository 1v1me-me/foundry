// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal Multicall3 for local anvil development.
/// Only implements aggregate3, which is the function viem calls.
contract Multicall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory returnData) {
        uint256 length = calls.length;
        returnData = new Result[](length);
        for (uint256 i = 0; i < length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (!calls[i].allowFailure && !success) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            returnData[i] = Result(success, ret);
        }
    }
}
