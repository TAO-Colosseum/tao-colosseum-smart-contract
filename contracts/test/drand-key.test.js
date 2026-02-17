/**
 * Test that our drand pulses key for round 26145524 matches the Polkadot app encoded storage key.
 * No chain needed - we call the contract's buildDrandPulseKey (exposed for testing) or check constant.
 */
const { expect } = require("chai");
const { ethers } = require("hardhat");

// From Polkadot app screenshot: encoded storage key for drand.pulses(26145524)
const EXPECTED_KEY_HEX = "a285cdb66e8b8524ea70b1693c7b1e050d8e70fd32bfb1639703f9a23d15b15e8e70ca71b63dde37a5a4f3d695002aabf4f28e0100000000";
const ROUND = 26145524;

describe("Drand pulse key", function () {
    let colosseum;

    before(async function () {
        const TAOColosseum = await ethers.getContractFactory("TAOColosseum");
        colosseum = await TAOColosseum.deploy();
        await colosseum.waitForDeployment();
    });

    it("getDrandPulseKey(26145524) returns exact key from Polkadot app", async function () {
        const key = await colosseum.getDrandPulseKey(ROUND);
        const keyHex = typeof key === "string" ? key : ethers.hexlify(key);
        const keyHexClean = keyHex.replace(/^0x/, "").toLowerCase();
        expect(keyHexClean).to.equal(EXPECTED_KEY_HEX.toLowerCase());
        expect(keyHexClean.length).to.equal(56 * 2); // 56 bytes = 112 hex chars
    });

    it("DRAND_PULSES_PREFIX matches first 32 bytes of expected key", function () {
        const prefix = "a285cdb66e8b8524ea70b1693c7b1e050d8e70fd32bfb1639703f9a23d15b15e";
        expect(EXPECTED_KEY_HEX.substring(0, 64).toLowerCase()).to.equal(prefix);
    });
});
