// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @dev Test helper: mimics the staking precompile interface used by RPS_Tournament.
 * Deployed in tests and installed at 0x0805 via hardhat_setCode.
 */
contract MockStakingPrecompile {
    mapping(bytes32 => mapping(uint256 => uint256)) public alphaByHotkeyAndNetuid;

    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable {
        alphaByHotkeyAndNetuid[hotkey][netuid] += amount;
    }

    function getTotalAlphaStaked(bytes32 hotkey, uint256 netuid) external view returns (uint256) {
        return alphaByHotkeyAndNetuid[hotkey][netuid];
    }

    function burnAlpha(bytes32 hotkey, uint256 amount, uint256 netuid) external payable {
        uint256 current = alphaByHotkeyAndNetuid[hotkey][netuid];
        require(current >= amount, "insufficient alpha");
        alphaByHotkeyAndNetuid[hotkey][netuid] = current - amount;
    }
}

