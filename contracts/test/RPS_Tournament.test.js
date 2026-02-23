const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RPS_Tournament", function () {
    let rps;
    let mockTle;
    let owner;
    let signers;
    const MIN_ENTRY = ethers.parseEther("0.5");

    beforeEach(async function () {
        signers = await ethers.getSigners();
        owner = signers[0];
        const MockTle = await ethers.getContractFactory("MockDrandTimelock");
        mockTle = await MockTle.deploy();
        await mockTle.waitForDeployment();
        const RPS = await ethers.getContractFactory("RPS_Tournament");
        rps = await RPS.deploy(await mockTle.getAddress());
        await rps.waitForDeployment();
    });

    describe("createTournament", function () {
        it("should create tournament with valid config (4, 8, 16)", async function () {
            await rps.createTournament(4, 3600, MIN_ENTRY, 10, 5, 5);
            const t = await rps.tournaments(1);
            expect(t.registrationEnd).to.be.gt(0);
            expect(await rps.nextTournamentId()).to.equal(2);

            await rps.createTournament(8, 7200, MIN_ENTRY, 10, 5, 5);
            await rps.createTournament(16, 3600, ethers.parseEther("1"), 5, 5, 3);
            expect(await rps.nextTournamentId()).to.equal(4);
        });

        it("should revert on invalid maxPlayers", async function () {
            await expect(rps.createTournament(2, 3600, MIN_ENTRY, 10, 5, 5)).to.be.revertedWithCustomError(rps, "InvalidMaxPlayers");
            await expect(rps.createTournament(3, 3600, MIN_ENTRY, 10, 5, 5)).to.be.revertedWithCustomError(rps, "InvalidMaxPlayers");
        });

        it("should revert on minEntry below 0.5 TAO", async function () {
            await expect(rps.createTournament(4, 3600, ethers.parseEther("0.1"), 10, 5, 5)).to.be.revertedWithCustomError(rps, "InvalidMinEntry");
        });
    });

    describe("register", function () {
        it("should allow registration with min entry", async function () {
            await rps.createTournament(4, 3600, MIN_ENTRY, 10, 5, 5);
            await expect(rps.connect(signers[1]).register(1, { value: MIN_ENTRY }))
                .to.emit(rps, "PlayerRegistered").withArgs(1, signers[1].address, MIN_ENTRY);
            expect((await rps.tournaments(1)).prizePool).to.equal(MIN_ENTRY);
        });

        it("should revert if already registered", async function () {
            await rps.createTournament(4, 3600, MIN_ENTRY, 10, 5, 5);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await expect(rps.connect(signers[1]).register(1, { value: MIN_ENTRY })).to.be.revertedWithCustomError(rps, "AlreadyRegistered");
        });

        it("should revert if insufficient value", async function () {
            await rps.createTournament(4, 3600, MIN_ENTRY, 10, 5, 5);
            await expect(rps.connect(signers[1]).register(1, { value: ethers.parseEther("0.1") })).to.be.revertedWithCustomError(rps, "InsufficientEntry");
        });
    });

    describe("cancelTournament", function () {
        it("should cancel and refund when time passed and < 2 players", async function () {
            await rps.createTournament(4, 60, MIN_ENTRY, 10, 5, 5);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await ethers.provider.send("evm_increaseTime", [61]);
            await ethers.provider.send("evm_mine", []);
            const balBefore = await ethers.provider.getBalance(signers[1].address);
            await expect(rps.cancelTournament(1)).to.emit(rps, "TournamentCanceled").withArgs(1);
            const balAfter = await ethers.provider.getBalance(signers[1].address);
            expect(balAfter - balBefore).to.equal(MIN_ENTRY);
            expect((await rps.tournaments(1)).phase).to.equal(2); // Canceled
        });

        it("should revert cancel when registration not ended", async function () {
            await rps.createTournament(4, 3600, MIN_ENTRY, 10, 5, 5);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await expect(rps.cancelTournament(1)).to.be.revertedWithCustomError(rps, "CannotCancel");
        });

        it("should revert cancel when >= 2 players", async function () {
            await rps.createTournament(4, 60, MIN_ENTRY, 10, 5, 5);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await rps.connect(signers[2]).register(1, { value: MIN_ENTRY });
            await ethers.provider.send("evm_increaseTime", [61]);
            await ethers.provider.send("evm_mine", []);
            await expect(rps.cancelTournament(1)).to.be.revertedWithCustomError(rps, "CannotCancel");
        });
    });

    describe("startTournament", function () {
        it("should revert start when drand unavailable (no precompile on local)", async function () {
            await rps.createTournament(4, 3600, MIN_ENTRY, 10, 5, 5);
            for (let i = 1; i <= 4; i++) await rps.connect(signers[i]).register(1, { value: MIN_ENTRY });
            await expect(rps.startTournament(1)).to.be.revertedWithCustomError(rps, "DrandUnavailable");
        });
    });

});
