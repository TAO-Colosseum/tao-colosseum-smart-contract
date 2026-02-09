const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * Gas Consumption Simulation Tests
 * 
 * Purpose: Ensure resolveGame() remains within block gas limits under high-load conditions,
 * specifically when filtering valid vs. late bets in _calculateValidPools().
 * 
 * Test Environment: Hardhat local network
 * Metric: Execution cost of resolveGame()
 * 
 * Key Constants from Contract:
 * - MAX_BETTORS_PER_GAME = 500
 * - BETTING_BLOCKS = 100
 * - FINAL_CALL_BLOCKS = 25 (blocks 75-99 are "final call" window)
 */

describe("Gas Consumption Simulation", function () {
    let colosseum;
    let owner;
    let signers;
    
    // Constants matching contract
    const MIN_BET_AMOUNT = ethers.parseEther("0.001");
    const BET_AMOUNT = ethers.parseEther("0.01");
    const BETTING_BLOCKS = 100;
    const FINAL_CALL_BLOCKS = 25;
    
    // Mock drand storage for testing
    let mockDrandRound = 1000n;
    
    beforeEach(async function () {
        // Get signers - we need 500+ for full simulation
        signers = await ethers.getSigners();
        owner = signers[0];
        
        console.log(`\n  Available signers: ${signers.length}`);
        
        // Deploy contract
        const TAOColosseum = await ethers.getContractFactory("TAOColosseum");
        colosseum = await TAOColosseum.deploy();
        await colosseum.waitForDeployment();
        
        console.log(`  Contract deployed at: ${await colosseum.getAddress()}`);
    });
    
    /**
     * Helper: Create multiple wallets and fund them
     */
    async function createFundedWallets(count) {
        const wallets = [];
        const fundAmount = ethers.parseEther("1");
        
        for (let i = 0; i < count; i++) {
            const wallet = ethers.Wallet.createRandom().connect(ethers.provider);
            wallets.push(wallet);
            
            // Fund the wallet from owner
            await owner.sendTransaction({
                to: wallet.address,
                value: fundAmount
            });
        }
        
        return wallets;
    }
    
    /**
     * Helper: Advance blocks
     */
    async function mineBlocks(count) {
        for (let i = 0; i < count; i++) {
            await ethers.provider.send("evm_mine", []);
        }
    }
    
    /**
     * Helper: Place bets from multiple wallets
     * @param wallets - Array of wallet signers
     * @param gameId - Game ID to bet on
     * @param side - 0 for Red, 1 for Blue
     * @param startIndex - Start index in wallets array
     * @param count - Number of bets to place
     */
    async function placeBets(wallets, gameId, side, startIndex, count) {
        const bets = [];
        for (let i = startIndex; i < startIndex + count && i < wallets.length; i++) {
            const tx = await colosseum.connect(wallets[i]).placeBet(gameId, side, {
                value: BET_AMOUNT
            });
            bets.push(tx);
        }
        // Wait for all bets to be mined
        await Promise.all(bets.map(tx => tx.wait()));
        return bets.length;
    }
    
    /**
     * Helper: Place dual bets (Red AND Blue) from wallets
     */
    async function placeDualBets(wallets, gameId, startIndex, count) {
        const bets = [];
        for (let i = startIndex; i < startIndex + count && i < wallets.length; i++) {
            // Bet on Red
            const txRed = await colosseum.connect(wallets[i]).placeBet(gameId, 0, {
                value: BET_AMOUNT
            });
            // Bet on Blue  
            const txBlue = await colosseum.connect(wallets[i]).placeBet(gameId, 1, {
                value: BET_AMOUNT
            });
            bets.push(txRed, txBlue);
        }
        await Promise.all(bets.map(tx => tx.wait()));
        return count;
    }

    /**
     * Scenario 1: Optimistic (Low Computation)
     * 
     * Configuration:
     * - Random End Block: 99 (Late in the game window)
     * - Participants: 500 users (Single side)
     * - Distribution: 100% of votes placed before block 99
     * 
     * Expected Load: Low. The loop iterates 500 times, but the 
     * if (betBlock < endBlock) condition is consistently TRUE.
     * Minimal logic required to separate pools (no refunds to calculate).
     */
    describe("Scenario 1: Optimistic (Low Computation)", function () {
        // Use smaller number for faster testing - scale up for real gas benchmarks
        const USER_COUNT = 50; // Use 500 for full simulation
        
        it("should measure gas for 100% valid bets (single side)", async function () {
            this.timeout(600000); // 10 minutes
            
            console.log(`\n    Creating ${USER_COUNT} funded wallets...`);
            const wallets = await createFundedWallets(USER_COUNT);
            
            // Start a new game
            console.log("    Starting new game...");
            const startTx = await colosseum.startNewGame();
            await startTx.wait();
            const gameId = await colosseum.currentGameId();
            
            // Get game info
            const game = await colosseum.getGame(gameId);
            console.log(`    Game ${gameId} started at block ${game.startBlock}`);
            console.log(`    End block: ${game.endBlock}`);
            console.log(`    Target drand round: ${game.targetDrandRound}`);
            
            // Place all bets early (before final call window)
            // All bets on Red side (single side scenario)
            console.log(`    Placing ${USER_COUNT} bets on Red (early)...`);
            const betCount = await placeBets(wallets, gameId, 0, 0, USER_COUNT);
            console.log(`    Placed ${betCount} bets`);
            
            // Also place some Blue bets to avoid "insufficient participation"
            console.log("    Placing minimum Blue bets for game validity...");
            await colosseum.connect(owner).placeBet(gameId, 1, { value: ethers.parseEther("0.5") });
            
            // Mine blocks to end betting period
            console.log("    Mining blocks to end betting period...");
            await mineBlocks(BETTING_BLOCKS + 5);
            
            // Phase 1: Transition to Calculating
            console.log("    Executing resolveGame phase 1 (Betting -> Calculating)...");
            const phase1Tx = await colosseum.resolveGame(gameId);
            const phase1Receipt = await phase1Tx.wait();
            console.log(`    Phase 1 gas used: ${phase1Receipt.gasUsed.toString()}`);
            
            // Note: Phase 2 requires actual drand randomness which we can't mock easily
            // In a real test environment, you'd need to either:
            // 1. Use a local testnet with drand integration
            // 2. Mock the storage precompile
            // 3. Deploy a modified contract for testing
            
            console.log("\n    === SCENARIO 1 RESULTS ===");
            console.log(`    Users: ${USER_COUNT}`);
            console.log(`    Bet distribution: 100% valid (before final call)`);
            console.log(`    Phase 1 gas: ${phase1Receipt.gasUsed.toString()}`);
            console.log("    Note: Phase 2 requires drand randomness (not available in hardhat)");
        });
    });

    /**
     * Scenario 2: Neutral (Mixed Computation)
     * 
     * Configuration:
     * - Random End Block: 88 (Mid-late window)
     * - Participants: 500 users (Single side)
     * - Distribution: 50% valid, 50% late (refund)
     * 
     * Expected Load: Medium. The contract must perform state writes 
     * for half the users to mark them as isLateBet.
     */
    describe("Scenario 2: Neutral (Mixed Computation)", function () {
        const USER_COUNT = 50; // Use 500 for full simulation
        
        it("should measure gas for 50/50 valid/late bets (single side)", async function () {
            this.timeout(600000);
            
            console.log(`\n    Creating ${USER_COUNT} funded wallets...`);
            const wallets = await createFundedWallets(USER_COUNT);
            
            // Start a new game
            console.log("    Starting new game...");
            await colosseum.startNewGame();
            const gameId = await colosseum.currentGameId();
            const game = await colosseum.getGame(gameId);
            
            console.log(`    Game ${gameId}: blocks ${game.startBlock} to ${game.endBlock}`);
            
            // Calculate final call window start (block 75 relative to start)
            const finalCallStart = Number(game.endBlock) - FINAL_CALL_BLOCKS;
            console.log(`    Final call window starts at block: ${finalCallStart}`);
            
            // Place 50% bets EARLY (before final call window)
            const earlyCount = Math.floor(USER_COUNT / 2);
            console.log(`    Placing ${earlyCount} EARLY bets on Red...`);
            await placeBets(wallets, gameId, 0, 0, earlyCount);
            
            // Add Blue bets for game validity
            await colosseum.connect(owner).placeBet(gameId, 1, { value: ethers.parseEther("0.5") });
            
            // Mine to final call window (but stay within betting period)
            let currentBlock = await ethers.provider.getBlockNumber();
            let blocksToMine = finalCallStart - currentBlock + 5;
            // Make sure we don't exceed endBlock
            const maxSafeBlocks = Number(game.endBlock) - currentBlock - USER_COUNT - 10;
            blocksToMine = Math.min(blocksToMine, maxSafeBlocks);
            if (blocksToMine > 0) {
                console.log(`    Mining ${blocksToMine} blocks to enter final call window...`);
                await mineBlocks(blocksToMine);
            }
            
            // Verify we're still in betting period
            currentBlock = await ethers.provider.getBlockNumber();
            console.log(`    Current block: ${currentBlock}, End block: ${game.endBlock}`);
            
            if (currentBlock < Number(game.endBlock) - USER_COUNT) {
                // Place 50% bets LATE (in final call window - may be invalidated)
                const lateCount = USER_COUNT - earlyCount;
                console.log(`    Placing ${lateCount} LATE bets on Red (in final call)...`);
                await placeBets(wallets, gameId, 0, earlyCount, lateCount);
            } else {
                console.log("    Skipping late bets - too close to end block");
            }
            
            // Mine to end betting
            currentBlock = await ethers.provider.getBlockNumber();
            const remainingBlocks = Number(game.endBlock) - currentBlock + 5;
            await mineBlocks(remainingBlocks);
            
            // Phase 1
            console.log("    Executing resolveGame phase 1...");
            const phase1Tx = await colosseum.resolveGame(gameId);
            const phase1Receipt = await phase1Tx.wait();
            
            console.log("\n    === SCENARIO 2 RESULTS ===");
            console.log(`    Users: ${USER_COUNT}`);
            console.log(`    Early bets: ${earlyCount}`);
            console.log(`    Phase 1 gas: ${phase1Receipt.gasUsed.toString()}`);
        });
    });

    /**
     * Scenario 3: Pessimistic (Worst Case / DoS Check)
     * 
     * Configuration:
     * - Random End Block: 88
     * - Participants: 500 distinct addresses
     * - Bet Structure: Double-sided betting (Each user bets Red AND Blue)
     * - Total iterated items: 1000 bets
     * - Distribution: 50% placed before block 88, 50% placed after
     * 
     * Expected Load: High. The loop must iterate 500 times but check 
     * two storage slots per user (Red and Blue).
     */
    describe("Scenario 3: Pessimistic (Dual-side, mixed)", function () {
        const USER_COUNT = 25; // Use 500 for full simulation (1000 total bets)
        
        it("should measure gas for dual-sided 50/50 bets", async function () {
            this.timeout(600000);
            
            console.log(`\n    Creating ${USER_COUNT} funded wallets (${USER_COUNT * 2} total bets)...`);
            const wallets = await createFundedWallets(USER_COUNT);
            
            // Start a new game
            console.log("    Starting new game...");
            await colosseum.startNewGame();
            const gameId = await colosseum.currentGameId();
            const game = await colosseum.getGame(gameId);
            
            const finalCallStart = Number(game.endBlock) - FINAL_CALL_BLOCKS;
            console.log(`    Final call window starts at block: ${finalCallStart}`);
            console.log(`    End block: ${game.endBlock}`);
            
            // Place 50% dual bets EARLY
            const earlyCount = Math.floor(USER_COUNT / 2);
            console.log(`    Placing ${earlyCount} EARLY dual bets (Red+Blue each)...`);
            await placeDualBets(wallets, gameId, 0, earlyCount);
            
            // Mine to final call window (but stay within betting period)
            let currentBlock = await ethers.provider.getBlockNumber();
            // Each dual bet uses 2 transactions, so account for that
            const lateCount = USER_COUNT - earlyCount;
            const neededBlocks = lateCount * 2 + 10; // Blocks needed for late bets + buffer
            const maxSafeBlock = Number(game.endBlock) - neededBlocks;
            let blocksToMine = Math.min(finalCallStart - currentBlock + 5, maxSafeBlock - currentBlock);
            
            if (blocksToMine > 0) {
                console.log(`    Mining ${blocksToMine} blocks to enter final call window...`);
                await mineBlocks(blocksToMine);
            }
            
            // Verify we can still place bets
            currentBlock = await ethers.provider.getBlockNumber();
            console.log(`    Current block: ${currentBlock}, End block: ${game.endBlock}`);
            
            if (currentBlock < Number(game.endBlock) - neededBlocks) {
                console.log(`    Placing ${lateCount} LATE dual bets (in final call)...`);
                await placeDualBets(wallets, gameId, earlyCount, lateCount);
            } else {
                console.log("    Skipping late bets - too close to end block");
            }
            
            // Mine to end betting
            currentBlock = await ethers.provider.getBlockNumber();
            const remainingBlocks = Number(game.endBlock) - currentBlock + 5;
            await mineBlocks(remainingBlocks);
            
            // Phase 1
            console.log("    Executing resolveGame phase 1...");
            const phase1Tx = await colosseum.resolveGame(gameId);
            const phase1Receipt = await phase1Tx.wait();
            
            console.log("\n    === SCENARIO 3 RESULTS ===");
            console.log(`    Users: ${USER_COUNT} (${USER_COUNT * 2} total bets)`);
            console.log(`    Early dual bets: ${earlyCount}`);
            console.log(`    Phase 1 gas: ${phase1Receipt.gasUsed.toString()}`);
        });
    });

    /**
     * Scenario 4: Ultra Pessimistic (Mass Invalid / All Refund)
     * 
     * Configuration:
     * - Random End Block: 1 (The very first block of the window)
     * - Participants: 500 distinct addresses
     * - Bet Structure: Double-sided betting (Red AND Blue per user)
     * - Distribution: 100% of votes placed after the calculated end block (all "Late")
     * 
     * Expected Load: Maximum / Critical.
     * This triggers worst-case complexity for _calculateValidPools.
     * The contract must iterate through all 1000 bet positions and 
     * execute an SSTORE for every single one to set isLateBet = true.
     * 
     * Note: This test places all bets late in the final call window to simulate
     * worst-case. In practice, the actual "late" determination happens at resolution
     * based on drand randomness.
     */
    describe("Scenario 4: Ultra Pessimistic (All Late)", function () {
        const USER_COUNT = 25; // Use 500 for full simulation (1000 total bets)
        
        it("should measure gas for bets placed in final call window", async function () {
            this.timeout(600000);
            
            console.log(`\n    Creating ${USER_COUNT} funded wallets (${USER_COUNT * 2} total bets)...`);
            const wallets = await createFundedWallets(USER_COUNT);
            
            // Start a new game
            console.log("    Starting new game...");
            await colosseum.startNewGame();
            const gameId = await colosseum.currentGameId();
            const game = await colosseum.getGame(gameId);
            
            const finalCallStart = Number(game.endBlock) - FINAL_CALL_BLOCKS;
            console.log(`    Final call window: blocks ${finalCallStart} to ${game.endBlock}`);
            
            // Calculate safe mining amount to stay within betting period
            let currentBlock = await ethers.provider.getBlockNumber();
            const neededBlocks = USER_COUNT * 2 + 10; // Blocks for dual bets + buffer
            const targetBlock = finalCallStart + 5; // Enter final call window
            const maxMineBlocks = Number(game.endBlock) - neededBlocks - currentBlock;
            const blocksToMine = Math.min(targetBlock - currentBlock, maxMineBlocks);
            
            if (blocksToMine > 0) {
                console.log(`    Mining ${blocksToMine} blocks to approach final call window...`);
                await mineBlocks(blocksToMine);
            }
            
            currentBlock = await ethers.provider.getBlockNumber();
            console.log(`    Current block: ${currentBlock}, End block: ${game.endBlock}`);
            
            // Place ALL dual bets (these will be "late" if actualEndBlock is before them)
            console.log(`    Placing ${USER_COUNT} dual bets in final call period...`);
            await placeDualBets(wallets, gameId, 0, USER_COUNT);
            
            // Mine to end betting
            currentBlock = await ethers.provider.getBlockNumber();
            const remainingBlocks = Number(game.endBlock) - currentBlock + 5;
            await mineBlocks(remainingBlocks);
            
            // Phase 1
            console.log("    Executing resolveGame phase 1...");
            const phase1Tx = await colosseum.resolveGame(gameId);
            const phase1Receipt = await phase1Tx.wait();
            
            console.log("\n    === SCENARIO 4 RESULTS ===");
            console.log(`    Users: ${USER_COUNT} (${USER_COUNT * 2} total bets)`);
            console.log(`    All bets placed in final call window`);
            console.log(`    Phase 1 gas: ${phase1Receipt.gasUsed.toString()}`);
            console.log("    Note: Actual late determination depends on drand randomness");
        });
    });

    /**
     * Full Scale Test - Run with 500 users
     * WARNING: This test takes a long time and uses significant resources
     * Only enable for actual gas benchmarking
     */
    describe.skip("Full Scale Benchmark (500 users)", function () {
        const USER_COUNT = 500;
        
        it("Scenario 3 Full: 500 users, dual-sided, 50/50 split", async function () {
            this.timeout(3600000); // 1 hour
            
            console.log(`\n    === FULL SCALE BENCHMARK ===`);
            console.log(`    Creating ${USER_COUNT} funded wallets...`);
            
            const wallets = await createFundedWallets(USER_COUNT);
            
            await colosseum.startNewGame();
            const gameId = await colosseum.currentGameId();
            const game = await colosseum.getGame(gameId);
            
            const finalCallStart = Number(game.endBlock) - FINAL_CALL_BLOCKS;
            
            // Early bets (250 users, 500 bets)
            console.log("    Placing 250 early dual bets...");
            await placeDualBets(wallets, gameId, 0, 250);
            
            // Mine to final call
            const currentBlock = await ethers.provider.getBlockNumber();
            await mineBlocks(finalCallStart - currentBlock + 5);
            
            // Late bets (250 users, 500 bets)
            console.log("    Placing 250 late dual bets...");
            await placeDualBets(wallets, gameId, 250, 250);
            
            // End betting
            await mineBlocks(FINAL_CALL_BLOCKS + 5);
            
            // Resolve
            console.log("    Resolving game...");
            const tx = await colosseum.resolveGame(gameId);
            const receipt = await tx.wait();
            
            console.log(`\n    === FULL SCALE RESULTS ===`);
            console.log(`    Total users: ${USER_COUNT}`);
            console.log(`    Total bets: ${USER_COUNT * 2}`);
            console.log(`    Phase 1 gas: ${receipt.gasUsed.toString()}`);
            
            // Check if gas is within block limit (30M for most chains)
            const BLOCK_GAS_LIMIT = 30_000_000n;
            expect(receipt.gasUsed).to.be.lessThan(BLOCK_GAS_LIMIT);
        });
    });

    /**
     * Emergency Withdraw Gas Test
     */
    describe("Emergency Withdraw Gas", function () {
        it("should measure gas for emergency withdrawal", async function () {
            this.timeout(120000);
            
            const wallet = (await createFundedWallets(1))[0];
            
            await colosseum.startNewGame();
            const gameId = await colosseum.currentGameId();
            const game = await colosseum.getGame(gameId);
            
            console.log(`\n    Game predictedDrandTimestamp: ${game.predictedDrandTimestamp}`);
            
            // Place dual bet
            await colosseum.connect(wallet).placeBet(gameId, 0, { value: BET_AMOUNT });
            await colosseum.connect(wallet).placeBet(gameId, 1, { value: BET_AMOUNT });
            
            // Fast forward past predictedDrandTimestamp + 7 days
            // Emergency timeout = predictedDrandTimestamp + 7 days - (100 blocks * 12s)
            const SEVEN_DAYS = 7 * 24 * 60 * 60;
            const BETTING_DURATION = 100 * 12; // 1200 seconds
            
            // Need to advance: predictedDrandTimestamp + SEVEN_DAYS - BETTING_DURATION - currentTime + buffer
            const currentBlock = await ethers.provider.getBlock('latest');
            const currentTime = currentBlock.timestamp;
            const emergencyUnlockTime = Number(game.predictedDrandTimestamp) + SEVEN_DAYS - BETTING_DURATION;
            const timeToAdvance = emergencyUnlockTime - currentTime + 100; // +100s buffer
            
            console.log(`    Current time: ${currentTime}`);
            console.log(`    Emergency unlock time: ${emergencyUnlockTime}`);
            console.log(`    Advancing time by: ${timeToAdvance} seconds`);
            
            await ethers.provider.send("evm_increaseTime", [timeToAdvance]);
            await ethers.provider.send("evm_mine", []);
            
            // Try emergency withdraw
            console.log("    Testing emergency withdraw gas...");
            const tx = await colosseum.connect(wallet).withdrawEmergency(gameId);
            const receipt = await tx.wait();
            
            console.log(`    Emergency withdraw gas: ${receipt.gasUsed.toString()}`);
        });
    });

    /**
     * Circuit Breaker Gas Test
     */
    describe("Circuit Breaker Gas", function () {
        it("should measure gas for voidCompromisedGame (time timeout)", async function () {
            this.timeout(120000);
            
            await colosseum.startNewGame();
            const gameId = await colosseum.currentGameId();
            const game = await colosseum.getGame(gameId);
            
            // Place some bets for a realistic scenario
            await colosseum.connect(owner).placeBet(gameId, 0, { value: ethers.parseEther("1") });
            await colosseum.connect(owner).placeBet(gameId, 1, { value: ethers.parseEther("1") });
            
            // Fast forward past predictedDrandTimestamp
            const predictedTime = Number(game.predictedDrandTimestamp);
            const currentTime = (await ethers.provider.getBlock('latest')).timestamp;
            const timeToAdvance = predictedTime - currentTime + 100;
            
            if (timeToAdvance > 0) {
                await ethers.provider.send("evm_increaseTime", [timeToAdvance]);
                await ethers.provider.send("evm_mine", []);
            }
            
            console.log("\n    Testing voidCompromisedGame gas...");
            const tx = await colosseum.voidCompromisedGame(gameId);
            const receipt = await tx.wait();
            
            console.log(`    voidCompromisedGame gas: ${receipt.gasUsed.toString()}`);
        });
    });
});
