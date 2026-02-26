const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RPS_Tournament", function () {
    let rps;
    let owner;
    let signers;
    const MIN_ENTRY = ethers.parseEther("0.5");
    const DRAND_PRECOMPILE = "0x000000000000000000000000000000000000080E";
    const STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805";

    async function installMockDrandPrecompile() {
        const Mock = await ethers.getContractFactory("MockDrandPrecompile");
        const mock = await Mock.deploy();
        await mock.waitForDeployment();
        const runtimeCode = await ethers.provider.getCode(mock.target);
        await ethers.provider.send("hardhat_setCode", [DRAND_PRECOMPILE, runtimeCode]);
    }

    async function installMockStakingPrecompile() {
        const Mock = await ethers.getContractFactory("MockStakingPrecompile");
        const mock = await Mock.deploy();
        await mock.waitForDeployment();
        const runtimeCode = await ethers.provider.getCode(mock.target);
        await ethers.provider.send("hardhat_setCode", [STAKING_PRECOMPILE, runtimeCode]);
    }

    async function mineTo(targetBlock) {
        while ((await ethers.provider.getBlockNumber()) < targetBlock) {
            await ethers.provider.send("evm_mine", []);
        }
    }

    const SN38_HOTKEY_DUMMY = "0x0000000000000000000000000000000000000000000000000000000000000000";

    beforeEach(async function () {
        signers = await ethers.getSigners();
        owner = signers[0];
        const RPS = await ethers.getContractFactory("RPS_Tournament");
        rps = await RPS.deploy(SN38_HOTKEY_DUMMY);
        await rps.waitForDeployment();
    });

    const MAX_REG = 50; // match contract MAX_REG_BLOCKS

    describe("createTournament", function () {
        it("should create tournament with valid config (4, 8, 16)", async function () {
            await rps.createTournament(4, 20, MIN_ENTRY);
            const t = await rps.tournaments(1);
            expect(t.registrationEndBlock).to.be.gt(0);
            expect(await rps.nextTournamentId()).to.equal(2);

            await rps.createTournament(8, 30, MIN_ENTRY);
            await rps.createTournament(16, MAX_REG, ethers.parseEther("1"));
            expect(await rps.nextTournamentId()).to.equal(4);
        });

        it("should revert on invalid maxPlayers", async function () {
            await expect(rps.createTournament(2, 20, MIN_ENTRY)).to.be.revertedWithCustomError(rps, "InvalidMaxPlayers");
            await expect(rps.createTournament(3, 20, MIN_ENTRY)).to.be.revertedWithCustomError(rps, "InvalidMaxPlayers");
        });

        it("should revert on minEntry below 0.5 TAO", async function () {
            await expect(rps.createTournament(4, 20, ethers.parseEther("0.1"))).to.be.revertedWithCustomError(rps, "InvalidMinEntry");
        });

        it("should revert on maxRegBlocks too large", async function () {
            const maxBlocks = await rps.MAX_REG_BLOCKS();
            await expect(rps.createTournament(4, maxBlocks + 1n, MIN_ENTRY)).to.be.revertedWithCustomError(rps, "InvalidMaxRegBlocks");
        });
    });

    describe("register", function () {
        it("should keep full entry in prizePool until tournament settlement", async function () {
            await rps.createTournament(4, 20, MIN_ENTRY);
            await expect(rps.connect(signers[1]).register(1, { value: MIN_ENTRY }))
                .to.emit(rps, "PlayerRegistered").withArgs(1, signers[1].address, MIN_ENTRY);
            expect((await rps.tournaments(1)).prizePool).to.equal(MIN_ENTRY);
            expect(await rps.accumulatedFees()).to.equal(0);
        });

        it("should revert if already registered", async function () {
            await rps.createTournament(4, 20, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await expect(rps.connect(signers[1]).register(1, { value: MIN_ENTRY })).to.be.revertedWithCustomError(rps, "AlreadyRegistered");
        });

        it("should revert if insufficient value", async function () {
            await rps.createTournament(4, 20, MIN_ENTRY);
            await expect(rps.connect(signers[1]).register(1, { value: ethers.parseEther("0.1") })).to.be.revertedWithCustomError(rps, "InsufficientOrExcessEntry");
        });
    });

    describe("unregister", function () {
        it("should allow unregister during registration and enable re-register", async function () {
            await rps.createTournament(4, 20, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });

            await expect(rps.connect(signers[1]).unregister(1))
                .to.emit(rps, "WithdrawalAccrued").withArgs(signers[1].address, MIN_ENTRY);

            expect(await rps.pendingWithdrawals(signers[1].address)).to.equal(MIN_ENTRY);
            expect((await rps.tournaments(1)).prizePool).to.equal(0);
            expect(await rps.accumulatedFees()).to.equal(0);

            // can register again after unregister
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            expect((await rps.tournaments(1)).prizePool).to.equal(MIN_ENTRY);
        });

        it("should revert unregister after registration ended", async function () {
            await rps.createTournament(4, 2, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            const t = await rps.tournaments(1);
            await mineTo(Number(t.registrationEndBlock));
            await expect(rps.connect(signers[1]).unregister(1))
                .to.be.revertedWithCustomError(rps, "RegistrationEnded");
        });
    });

    describe("cancelTournament", function () {
        it("should cancel and refund when time passed and < 2 players", async function () {
            await rps.createTournament(4, 2, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            const t = await rps.tournaments(1);
            await mineTo(Number(t.registrationEndBlock));
            await expect(rps.cancelTournament(1)).to.emit(rps, "TournamentCanceled").withArgs(1);
            // Refunds are pull-based now
            expect(await rps.pendingWithdrawals(signers[1].address)).to.equal(MIN_ENTRY);
            expect((await rps.tournaments(1)).phase).to.equal(2); // Canceled
        });

        it("should revert cancel when registration not ended", async function () {
            await rps.createTournament(4, 20, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await expect(rps.cancelTournament(1)).to.be.revertedWithCustomError(rps, "CannotCancel");
        });

        it("should revert cancel when >= 2 players", async function () {
            await rps.createTournament(4, 10, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await rps.connect(signers[2]).register(1, { value: MIN_ENTRY });
            const t = await rps.tournaments(1);
            await mineTo(Number(t.registrationEndBlock));
            await expect(rps.cancelTournament(1)).to.be.revertedWithCustomError(rps, "CannotCancel");
        });
    });

    describe("startTournament", function () {
        it("should revert start when drand unavailable (no precompile on local)", async function () {
            await rps.createTournament(4, 20, MIN_ENTRY);
            for (let i = 1; i <= 4; i++) await rps.connect(signers[i]).register(1, { value: MIN_ENTRY });
            await expect(rps.startTournament(1)).to.be.revertedWithCustomError(rps, "DrandUnavailable");
        });
    });

    describe("safety checks", function () {
        it("should reject direct ETH transfers", async function () {
            await expect(signers[1].sendTransaction({ to: rps.target, value: MIN_ENTRY }))
                .to.be.revertedWithCustomError(rps, "DirectETHNotAccepted");
        });

        it("should revert tryRevealMatch for invalid round/matchIndex", async function () {
            await installMockDrandPrecompile();
            await rps.createTournament(4, 20, MIN_ENTRY);
            for (let i = 1; i <= 4; i++) await rps.connect(signers[i]).register(1, { value: MIN_ENTRY });
            await rps.startTournament(1);

            // round 0 exists, but matchIndex 999 doesn't
            await expect(rps.tryRevealMatch(1, 0, 999)).to.be.revertedWithCustomError(rps, "InvalidMatchIndex");
            // round 1 doesn't exist yet (currentRound is 0)
            await expect(rps.tryRevealMatch(1, 1, 0)).to.be.revertedWithCustomError(rps, "InvalidRound");
        });
    });

    describe("tie replay", function () {
        it("should replay on tie up to max rounds then drand", async function () {
            await installMockDrandPrecompile();
            await rps.createTournament(4, 20, MIN_ENTRY); // fixed config
            for (let i = 1; i <= 4; i++) await rps.connect(signers[i]).register(1, { value: MIN_ENTRY });
            await rps.startTournament(1);

            // Grab first match in round 0.
            let m = await rps.matches(1, 0, 0);
            const playerA = m.playerA;
            const playerB = m.playerB;
            const signerA = signers.find(s => s.address === playerA);
            const signerB = signers.find(s => s.address === playerB);

            const choice = 1; // Rock
            const coder = ethers.AbiCoder.defaultAbiCoder();

            async function mineTo(targetBlock) {
                while ((await ethers.provider.getBlockNumber()) < targetBlock) {
                    await ethers.provider.send("evm_mine", []);
                }
            }

            // ---- RPS round 0: tie, should replay ----
            const rr0 = 0;
            const saltA0 = ethers.hexlify(ethers.randomBytes(32));
            const saltB0 = ethers.hexlify(ethers.randomBytes(32));
            const commitA0 = ethers.keccak256(coder.encode(
                ["uint256","uint256","uint256","uint256","address","uint8","bytes32"],
                [1, 0, 0, rr0, playerA, choice, saltA0]
            ));
            const commitB0 = ethers.keccak256(coder.encode(
                ["uint256","uint256","uint256","uint256","address","uint8","bytes32"],
                [1, 0, 0, rr0, playerB, choice, saltB0]
            ));

            await rps.connect(signerA).commitMove(1, 0, 0, commitA0);
            await rps.connect(signerB).commitMove(1, 0, 0, commitB0);

            m = await rps.matches(1, 0, 0);
            await mineTo(Number(m.commitEndBlock) + 1);

            await rps.connect(signerA).revealMove(1, 0, 0, choice, saltA0);
            await rps.connect(signerB).revealMove(1, 0, 0, choice, saltB0);

            m = await rps.matches(1, 0, 0);
            await mineTo(Number(m.revealEndBlock) + 1);

            await expect(rps.tryRevealMatch(1, 0, 0)).to.emit(rps, "MatchReplayed");
            m = await rps.matches(1, 0, 0);
            expect(m.winner).to.equal(ethers.ZeroAddress);
            expect(m.rpsRound).to.equal(1);

            // ---- RPS round 1: tie, should replay again (max rounds = 3) ----
            const rr1 = 1;
            const saltA1 = ethers.hexlify(ethers.randomBytes(32));
            const saltB1 = ethers.hexlify(ethers.randomBytes(32));
            const commitA1 = ethers.keccak256(coder.encode(
                ["uint256","uint256","uint256","uint256","address","uint8","bytes32"],
                [1, 0, 0, rr1, playerA, choice, saltA1]
            ));
            const commitB1 = ethers.keccak256(coder.encode(
                ["uint256","uint256","uint256","uint256","address","uint8","bytes32"],
                [1, 0, 0, rr1, playerB, choice, saltB1]
            ));

            await rps.connect(signerA).commitMove(1, 0, 0, commitA1);
            await rps.connect(signerB).commitMove(1, 0, 0, commitB1);

            m = await rps.matches(1, 0, 0);
            await mineTo(Number(m.commitEndBlock) + 1);

            await rps.connect(signerA).revealMove(1, 0, 0, choice, saltA1);
            await rps.connect(signerB).revealMove(1, 0, 0, choice, saltB1);

            m = await rps.matches(1, 0, 0);
            await mineTo(Number(m.revealEndBlock) + 1);

            await expect(rps.tryRevealMatch(1, 0, 0)).to.emit(rps, "MatchReplayed");
            m = await rps.matches(1, 0, 0);
            // after rr1 tie, should be replayed to rr2
            expect(m.winner).to.equal(ethers.ZeroAddress);
            expect(m.rpsRound).to.equal(2);

            // ---- RPS round 2: tie again, should resolve via drand ----
            const rr2 = 2;
            const saltA2 = ethers.hexlify(ethers.randomBytes(32));
            const saltB2 = ethers.hexlify(ethers.randomBytes(32));
            const commitA2 = ethers.keccak256(coder.encode(
                ["uint256","uint256","uint256","uint256","address","uint8","bytes32"],
                [1, 0, 0, rr2, playerA, choice, saltA2]
            ));
            const commitB2 = ethers.keccak256(coder.encode(
                ["uint256","uint256","uint256","uint256","address","uint8","bytes32"],
                [1, 0, 0, rr2, playerB, choice, saltB2]
            ));

            await rps.connect(signerA).commitMove(1, 0, 0, commitA2);
            await rps.connect(signerB).commitMove(1, 0, 0, commitB2);

            m = await rps.matches(1, 0, 0);
            await mineTo(Number(m.commitEndBlock) + 1);

            await rps.connect(signerA).revealMove(1, 0, 0, choice, saltA2);
            await rps.connect(signerB).revealMove(1, 0, 0, choice, saltB2);

            m = await rps.matches(1, 0, 0);
            await mineTo(Number(m.revealEndBlock) + 1);

            await expect(rps.tryRevealMatch(1, 0, 0)).to.emit(rps, "MatchResolved");
            m = await rps.matches(1, 0, 0);
            expect(m.winner).to.not.equal(ethers.ZeroAddress);
        });
    });

    describe("fee accounting safety", function () {
        it("should allow full unregister refund even if flush is attempted during registration", async function () {
            await installMockStakingPrecompile();
            await rps.createTournament(4, 20, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });

            // No fees exist before tournament settlement; flush should be a no-op.
            await expect(rps.flushFeesToSubnetAndBurn()).to.not.be.reverted;
            expect(await rps.accumulatedFees()).to.equal(0);

            await expect(rps.connect(signers[1]).unregister(1))
                .to.emit(rps, "WithdrawalAccrued")
                .withArgs(signers[1].address, MIN_ENTRY);

            expect(await rps.pendingWithdrawals(signers[1].address)).to.equal(MIN_ENTRY);
            expect((await rps.tournaments(1)).prizePool).to.equal(0);
            expect(await rps.totalPrizeLiability()).to.equal(0);
        });

        it("should split fee exactly at claim time and keep dust in winner payout", async function () {
            await installMockDrandPrecompile();
            await installMockStakingPrecompile();

            const oddEntry = MIN_ENTRY + 1n; // force odd-wei total pot for deterministic floor division behavior
            await rps.createTournament(4, 10, oddEntry);
            await rps.connect(signers[1]).register(1, { value: oddEntry });
            await rps.connect(signers[2]).register(1, { value: oddEntry });

            const reg = await rps.tournaments(1);
            await mineTo(Number(reg.registrationEndBlock));
            await rps.startTournament(1);

            // Resolve the only match by no-show path (both uncommitted => drand tiebreak winner).
            const match = await rps.matches(1, 0, 0);
            await mineTo(Number(match.revealEndBlock) + 1);
            await rps.tryRevealMatch(1, 0, 0);

            const tBeforeClaim = await rps.tournaments(1);
            expect(tBeforeClaim.phase).to.equal(3); // Completed
            expect(await rps.accumulatedFees()).to.equal(0);

            const totalPot = oddEntry * 2n;
            expect(tBeforeClaim.prizePool).to.equal(totalPot);

            const expectedFee = (totalPot * 150n) / 10000n;
            const expectedPayout = totalPot - expectedFee;
            const winner = tBeforeClaim.winner;
            const winnerSigner = signers.find((s) => s.address === winner);
            expect(winnerSigner).to.not.equal(undefined);

            await expect(rps.connect(winnerSigner).claimPrize(1))
                .to.emit(rps, "PrizeClaimed")
                .withArgs(1, winner, expectedPayout);

            const tAfterClaim = await rps.tournaments(1);
            expect(tAfterClaim.prizePool).to.equal(0);
            expect(await rps.totalPrizeLiability()).to.equal(0);
            expect(await rps.accumulatedFees()).to.equal(expectedFee);
        });

        it("should allow stalled cancel refunds after a flush attempt", async function () {
            await installMockDrandPrecompile();
            await installMockStakingPrecompile();

            await rps.createTournament(4, 10, MIN_ENTRY);
            await rps.connect(signers[1]).register(1, { value: MIN_ENTRY });
            await rps.connect(signers[2]).register(1, { value: MIN_ENTRY });

            const reg = await rps.tournaments(1);
            await mineTo(Number(reg.registrationEndBlock));
            await rps.startTournament(1);

            // Fees are only collected at claim time, so this remains a safe no-op.
            await expect(rps.flushFeesToSubnetAndBurn()).to.not.be.reverted;
            expect(await rps.accumulatedFees()).to.equal(0);

            const stalled = await rps.tournaments(1);
            const stallBlocks = await rps.STALL_BLOCKS();
            await mineTo(Number(stalled.roundStartBlock + stallBlocks + 1n));

            await expect(rps.cancelStalledTournament(1))
                .to.emit(rps, "TournamentCanceled")
                .withArgs(1);

            expect(await rps.pendingWithdrawals(signers[1].address)).to.equal(MIN_ENTRY);
            expect(await rps.pendingWithdrawals(signers[2].address)).to.equal(MIN_ENTRY);
            expect((await rps.tournaments(1)).prizePool).to.equal(0);
            expect(await rps.totalPrizeLiability()).to.equal(0);
            expect(await rps.accumulatedFees()).to.equal(0);
        });
    });

});
