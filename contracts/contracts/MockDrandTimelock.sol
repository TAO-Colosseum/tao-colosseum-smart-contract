// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockDrandTimelock
 * @notice Mock for TLE precompile: stores ciphertext -> plaintext for testing.
 * @dev In tests, call setPlaintext(ciphertext, plaintext) then decryptTimelock returns that plaintext.
 */
contract MockDrandTimelock {
    mapping(bytes32 => bytes) private _plaintextByHash;

    /**
     * @notice Register a ciphertext -> plaintext mapping for tests.
     * @param ciphertext The TLE ciphertext (or any bytes).
     * @param plaintext The plaintext to return when decryptTimelock(ciphertext, round) is called.
     */
    function setPlaintext(bytes calldata ciphertext, bytes calldata plaintext) external {
        _plaintextByHash[keccak256(ciphertext)] = plaintext;
    }

    /**
     * @notice Decrypt: returns stored plaintext for this ciphertext if set; otherwise (false, "").
     * @param ciphertext Ciphertext (round is ignored in mock).
     */
    function decryptTimelock(bytes calldata ciphertext, uint64 /* round */)
        external
        view
        returns (bool success, bytes memory plaintext)
    {
        bytes storage p = _plaintextByHash[keccak256(ciphertext)];
        if (p.length == 0) return (false, "");
        return (true, p);
    }
}
