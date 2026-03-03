// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @dev Test helper: mimics the optional drand precompile interface used by the contracts.
 * Deployed in tests and its runtime bytecode is installed at the precompile address via hardhat_setCode.
 */
contract MockDrandPrecompile {
    function getLastStoredRound() external pure returns (uint64) {
        return 1_000_000;
    }

    function getRandomness(uint64 round) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("mock-drand", round));
    }
}

