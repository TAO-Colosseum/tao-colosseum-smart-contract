// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TAOColosseum
 * @notice P2P Underdog betting game on Bittensor EVM - the minority side wins!
 * @dev Minimal-trust design with limited owner privileges:
 *   - All parameters (including fees) are IMMUTABLE constants - hardcoded in bytecode
 *   - Fee is ALWAYS 1.5% - owner CANNOT change it or drain the contract
 *   - Owner can ONLY: withdraw earned fees (cannot affect games or user funds)
 *   - NO pause mechanism - protocol runs autonomously
 *   - Deterministic drand initialization (randomness committed at game creation)
 *   - Circuit breaker: permissionless voidCompromisedGame() for chain halt scenarios
 *   - Emergency withdraw: users can recover funds after 7 days if game stuck
 *   - Dual-position betting (bet on BOTH Red AND Blue)
 *   - Leaderboard tracking for top winners
 *   - Native TAO betting
 *   - All games are 100 blocks (~20 minutes)
 */
contract TAOColosseum is ReentrancyGuard, Ownable {

    // ==================== ENUMS ====================
    
    enum Side {
        Red,
        Blue
    }
    
    enum GamePhase {
        NotStarted,
        Betting,
        Calculating,
        Resolved,
        Finalized
    }

    // ==================== STRUCTS ====================
    
    struct Game {
        uint256 id;
        GamePhase phase;
        uint256 redPool;
        uint256 bluePool;
        uint256 redBettors;
        uint256 blueBettors;
        uint256 startBlock;
        uint256 endBlock;
        uint256 resolvedBlock;
        Side winningSide;
        uint256 totalLiquidity;
        bool hasWinner;
        // Anti-sniping: random end block within final call window (drand-based)
        uint64 targetDrandRound;    // Drand round committed to for randomness (set at game start)
        uint256 predictedDrandTimestamp; // Expected wall-clock time for drand round (for timeout check)
        uint256 actualEndBlock;     // Randomly selected end (only valid bets before this count)
        uint256 validRedPool;       // Pool from valid bets only
        uint256 validBluePool;      // Pool from valid bets only
        uint256 validLiquidity;     // Liquidity from valid bets only
    }
    
    struct SideBet {
        uint256 amount;
        uint256 placedAtBlock;  // Track when bet was placed for anti-sniping
        bool claimed;
        bool isLateBet;         // True if placed after actualEndBlock (refund only)
    }
    
    struct UserBets {
        SideBet redBet;
        SideBet blueBet;
    }
    
    struct UserStats {
        uint256 totalBets;
        uint256 totalWins;
        uint256 totalWinnings;
        uint256 totalLosses;
    }

    // ==================== CUSTOM ERRORS ====================
    
    error GameNotFound();
    error GameNotInBettingPhase();
    error GameAlreadyResolved();
    error GameNotResolved();
    error BettingPeriodEnded();
    error BettingPeriodNotEnded();
    error InvalidBetAmount();
    error NoBetToClaim();
    error AlreadyClaimed();
    error TransferFailed();
    error NoActiveGame();
    error GameStillActive();
    error BetTooSmall();
    error WaitingForRandomness();
    error LateBetRefundOnly();
    error TooManyBettors();
    error DrandPulseNotAvailable();
    error DrandPrecompileCallFailed();
    error RandomnessAlreadyLeaked();
    error ChainLaggingBehindRealTime();
    error GameNotCompromised();
    error EmergencyTimeoutNotReached();
    error NothingToWithdraw();
    error InsufficientFeesForRefund();
    error InsufficientGameBalance();

    // ==================== IMMUTABLE CONSTANTS ====================
    // SECURITY NOTE: All values below are compile-time constants (using 'constant' keyword).
    // They are hardcoded into the bytecode and CANNOT be changed by anyone - not even the owner.
    // This guarantees the fee will ALWAYS be 1.5% - the owner cannot drain the contract by changing fees.
    
    uint256 public constant PLATFORM_FEE = 150;              // 1.5% fee (immutable, cannot be changed)
    uint256 public constant FEE_DENOMINATOR = 10000;         // Fee basis points (immutable)
    uint256 public constant MIN_BET_AMOUNT = 0.001 ether;    // 0.001 TAO minimum
    uint256 public constant MIN_TOTAL_BETS = 2;              // 2 bettors minimum
    uint256 public constant MIN_POOL_SIZE = 0.5 ether;       // 0.5 TAO minimum
    
    // Block-based durations (~12s/block on Bittensor EVM)
    // Using blocks instead of timestamps handles chain halting gracefully
    uint256 public constant BETTING_BLOCKS = 100;            // ~20 minutes
    uint256 public constant FINAL_CALL_BLOCKS = 25;          // ~5 minutes (last 25 blocks)
    uint256 public constant MAX_BETTORS_PER_GAME = 500;      // Prevent gas DoS in _calculateValidPools
    uint256 public constant MAX_LEADERBOARD_SIZE = 100;
    
    // ==================== DRAND RANDOMNESS CONSTANTS ====================
    
    // Substrate storage precompile for reading runtime storage
    address public constant STORAGE_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    
    // Drand pallet storage key prefixes (from substrate metadata)
    // drand.pulses prefix (StorageMap with Blake2_128Concat hasher)
    bytes public constant DRAND_PULSES_PREFIX = hex"a285cdb66e8b8524ea70b1693c7b1e050d8e70fd32bfb1639703f9a23d15b15e";
    // drand.lastStoredRound key (StorageValue)
    bytes32 public constant DRAND_LAST_ROUND_KEY = 0xa285cdb66e8b8524ea70b1693c7b1e05087f3dd6e0ceded0e388dd34f810a73d;
    
    // Drand configuration
    uint256 public constant DRAND_ROUND_BUFFER = 3;          // Safety buffer rounds for unpredictability
    uint256 public constant DRAND_FREQUENCY_SECONDS = 3;     // Drand quicknet emits every 3 seconds
    uint256 public constant BLOCK_TIME_SECONDS = 12;         // Bittensor EVM ~12s per block
    uint256 public constant EMERGENCY_TIMEOUT = 7 days;      // Emergency withdraw timeout
    // Grace period before "chain lagging" can void: only allow void when this many seconds
    // past predicted drand time (avoids griefing normal committed games; ~9s gap at commit)
    uint256 public constant CHAIN_LAG_GRACE_SECONDS = 10 minutes;

    // ==================== STATE VARIABLES ====================
    
    uint256 public nextGameId = 1;
    uint256 public currentGameId = 0;
    uint256 public accumulatedFees;
    
    // Mappings
    mapping(uint256 => Game) public games;
    mapping(uint256 => mapping(address => mapping(Side => SideBet))) public sideBets;
    mapping(uint256 => address[]) public gameBettors;
    mapping(uint256 => uint256) public gameBalance;
    mapping(uint256 => uint256) public gameFees;
    mapping(uint256 => mapping(address => bool)) public hasAnyBet;
    mapping(address => UserStats) public userStats;
    
    // Leaderboard
    address[] public leaderboard;

    // ==================== EVENTS ====================
    
    event GameCreated(
        uint256 indexed gameId,
        uint256 startBlock,
        uint256 endBlock
    );
    
    event BetPlaced(
        uint256 indexed gameId,
        address indexed bettor,
        Side side,
        uint256 amount,
        uint256 newPoolTotal
    );
    
    event GameResolved(
        uint256 indexed gameId,
        Side winningSide,
        uint256 redPool,
        uint256 bluePool,
        uint256 redBettors,
        uint256 blueBettors
    );
    
    event WinningsClaimed(
        uint256 indexed gameId,
        address indexed bettor,
        Side side,
        uint256 betAmount,
        uint256 winnings
    );
    
    event GameCancelled(uint256 indexed gameId, string reason);
    event RefundClaimed(uint256 indexed gameId, address indexed bettor, Side side, uint256 amount);
    event FeesReleased(uint256 indexed gameId, uint256 platformFees);
    event GameTied(uint256 indexed gameId, uint256 redPool, uint256 bluePool);
    event ActualEndBlockSet(uint256 indexed gameId, uint256 actualEndBlock, uint256 validRedPool, uint256 validBluePool);
    event LateBetRefunded(uint256 indexed gameId, address indexed bettor, Side side, uint256 amount);
    event RandomnessUsed(uint256 indexed gameId, uint64 drandRound, bytes32 randomness);
    event GameVoided(uint256 indexed gameId, string reason);
    event EmergencyWithdraw(uint256 indexed gameId, address indexed user, uint256 redAmount, uint256 blueAmount);

    // ==================== CONSTRUCTOR ====================
    
    constructor() {}

    // ==================== MAIN FUNCTIONS ====================
    
    /**
     * @notice Start a new game (anyone can call)
     * @dev All games are 100 blocks (~20 minutes)
     *      Deterministic drand initialization: targetDrandRound is computed at game creation
     */
    function startNewGame() external {
        if (currentGameId > 0) {
            Game storage prevGame = games[currentGameId];
            if (prevGame.phase == GamePhase.Betting) revert GameStillActive();
            if (prevGame.phase == GamePhase.Calculating) revert GameStillActive();
        }
        
        uint256 gameId = nextGameId++;
        uint256 startBlock = block.number;
        uint256 endBlock = startBlock + BETTING_BLOCKS;
        
        // Deterministic drand initialization:
        // Calculate targetDrandRound at game creation for verifiable, immutable randomness target
        // Formula: CurrentRound + (GameDuration / DrandFrequency) + SafetyBuffer
        uint64 lastRound = _getLastStoredRound();
        uint256 gameDurationSeconds = BETTING_BLOCKS * BLOCK_TIME_SECONDS;
        uint256 drandRoundsForGame = gameDurationSeconds / DRAND_FREQUENCY_SECONDS;
        uint64 targetRound = lastRound + uint64(drandRoundsForGame) + uint64(DRAND_ROUND_BUFFER);
        
        // Calculate predicted wall-clock timestamp for the target drand round
        // Each drand round is DRAND_FREQUENCY_SECONDS apart
        uint256 roundsUntilTarget = uint256(targetRound - lastRound);
        uint256 predictedTimestamp = block.timestamp + (roundsUntilTarget * DRAND_FREQUENCY_SECONDS);
        
        games[gameId] = Game({
            id: gameId,
            phase: GamePhase.Betting,
            redPool: 0,
            bluePool: 0,
            redBettors: 0,
            blueBettors: 0,
            startBlock: startBlock,
            endBlock: endBlock,
            resolvedBlock: 0,
            winningSide: Side.Red,
            totalLiquidity: 0,
            hasWinner: false,
            targetDrandRound: targetRound,
            predictedDrandTimestamp: predictedTimestamp,
            actualEndBlock: 0,
            validRedPool: 0,
            validBluePool: 0,
            validLiquidity: 0
        });
        
        currentGameId = gameId;
        
        emit GameCreated(gameId, startBlock, endBlock);
    }
    
    /**
     * @notice Place a bet on a side (can bet on BOTH sides)
     * @param _gameId Game to bet on
     * @param _side Red or Blue
     */
    function placeBet(uint256 _gameId, Side _side) external payable nonReentrant {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        if (msg.value == 0) revert InvalidBetAmount();
        if (msg.value < MIN_BET_AMOUNT) revert BetTooSmall();
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) revert GameNotInBettingPhase();
        if (block.number >= game.endBlock) revert BettingPeriodEnded();
        
        SideBet storage existingBet = sideBets[_gameId][msg.sender][_side];
        
        // Calculate flat 1.5% fee
        uint256 feeAmount = (msg.value * PLATFORM_FEE) / FEE_DENOMINATOR;
        uint256 netAmount = msg.value - feeAmount;
        
        // Track fees per game (released only on resolution)
        gameFees[_gameId] += feeAmount;
        gameBalance[_gameId] += netAmount;
        
        // Check if new bettor on this side
        bool isNewBettorOnSide = existingBet.amount == 0;
        
        // Update bet
        existingBet.amount += msg.value;
        existingBet.placedAtBlock = block.number;  // Track when bet was placed
        existingBet.claimed = false;
        existingBet.isLateBet = false;  // Will be determined at resolution
        
        // Update pools
        if (_side == Side.Red) {
            game.redPool += msg.value;
            if (isNewBettorOnSide) game.redBettors++;
        } else {
            game.bluePool += msg.value;
            if (isNewBettorOnSide) game.blueBettors++;
        }
        
        game.totalLiquidity += netAmount;
        
        // Track bettor (only add once)
        if (!hasAnyBet[_gameId][msg.sender]) {
            // Prevent gas DoS - limit bettors per game
            if (gameBettors[_gameId].length >= MAX_BETTORS_PER_GAME) revert TooManyBettors();
            
            hasAnyBet[_gameId][msg.sender] = true;
            gameBettors[_gameId].push(msg.sender);
        }
        
        userStats[msg.sender].totalBets++;
        
        uint256 newPoolTotal = _side == Side.Red ? game.redPool : game.bluePool;
        emit BetPlaced(_gameId, msg.sender, _side, msg.value, newPoolTotal);
    }
    
    /**
     * @notice Resolve a game after betting ends
     * @dev Drand round is pre-committed at game creation (deterministic initialization)
     *      Phase 1: Move from Betting to Calculating after betting ends
     *      Phase 2: Use drand pulse to determine actual end, filter late bets
     * @param _gameId Game to resolve
     */
    function resolveGame(uint256 _gameId) external {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        
        // PHASE 1: Transition from Betting to Calculating
        if (game.phase == GamePhase.Betting) {
            if (block.number < game.endBlock) revert BettingPeriodNotEnded();
            
            // targetDrandRound was already set at game creation (deterministic initialization)
            // Just transition to Calculating phase
            game.phase = GamePhase.Calculating;
            return;
        }
        
        // PHASE 2: Finalize with drand randomness
        if (game.phase == GamePhase.Calculating) {
            // Try to get randomness from pre-committed drand round
            (bool pulseExists, bytes32 randomness) = _getDrandRandomness(game.targetDrandRound);
            
            // If pulse not yet available, caller must wait and try again
            if (!pulseExists) {
                revert WaitingForRandomness();
            }
            
            // Emit the randomness used for transparency/verification
            emit RandomnessUsed(_gameId, game.targetDrandRound, randomness);
            
            uint256 finalCallStart = game.endBlock - FINAL_CALL_BLOCKS;
            
            // Use drand randomness to pick actual end block within final call window
            // Note: randomness can be any value including bytes32(0), which is valid
            uint256 randomOffset = uint256(randomness) % FINAL_CALL_BLOCKS;
            game.actualEndBlock = finalCallStart + randomOffset;
            
            // Calculate valid pools (excluding late bets)
            _calculateValidPools(_gameId);
            
            emit ActualEndBlockSet(_gameId, game.actualEndBlock, game.validRedPool, game.validBluePool);
            
            // Check minimum participation with VALID pools
            uint256 totalValidPool = game.validRedPool + game.validBluePool;
            
            if (totalValidPool < MIN_POOL_SIZE || game.validRedPool == 0 || game.validBluePool == 0) {
                _cancelGame(_gameId, "Insufficient valid participation after anti-snipe filter");
                return;
            }
            
            // Check for exact tie in valid pools
            if (game.validRedPool == game.validBluePool) {
                emit GameTied(_gameId, game.validRedPool, game.validBluePool);
                _cancelGame(_gameId, "Exact tie - refunding all bets");
                return;
            }
            
            // Underdog wins (minority side based on VALID pools)
            Side winner = game.validRedPool < game.validBluePool ? Side.Red : Side.Blue;
            
            game.winningSide = winner;
            game.hasWinner = true;
            game.phase = GamePhase.Resolved;
            game.resolvedBlock = block.number;
            
            // Release fees to accumulatedFees (owner can withdraw via withdrawFees())
            // Late bets get full refund including fees
            uint256 releasedFees = gameFees[_gameId];
            accumulatedFees += releasedFees;
            gameFees[_gameId] = 0;
            
            emit FeesReleased(_gameId, releasedFees);
            
            emit GameResolved(
                _gameId,
                winner,
                game.validRedPool,
                game.validBluePool,
                game.redBettors,
                game.blueBettors
            );
            return;
        }
        
        revert GameAlreadyResolved();
    }
    
    /**
     * @notice Calculate valid pools by filtering out late bets
     * @dev Iterates through all bettors to sum valid bets and mark late bets
     */
    function _calculateValidPools(uint256 _gameId) internal {
        Game storage game = games[_gameId];
        address[] storage bettors = gameBettors[_gameId];
        
        uint256 validRedPool = 0;
        uint256 validBluePool = 0;
        uint256 validLiquidity = 0;
        uint256 lateFees = 0;
        
        for (uint256 i = 0; i < bettors.length; i++) {
            address bettor = bettors[i];
            
            // Check Red bet
            SideBet storage redBet = sideBets[_gameId][bettor][Side.Red];
            if (redBet.amount > 0) {
                if (redBet.placedAtBlock < game.actualEndBlock) {
                    // Valid bet - count towards pool
                    validRedPool += redBet.amount;
                    uint256 fee = (redBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    validLiquidity += redBet.amount - fee;
                } else {
                    // Late bet - mark for refund
                    redBet.isLateBet = true;
                    uint256 fee = (redBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    lateFees += fee;
                }
            }
            
            // Check Blue bet
            SideBet storage blueBet = sideBets[_gameId][bettor][Side.Blue];
            if (blueBet.amount > 0) {
                if (blueBet.placedAtBlock < game.actualEndBlock) {
                    // Valid bet - count towards pool
                    validBluePool += blueBet.amount;
                    uint256 fee = (blueBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    validLiquidity += blueBet.amount - fee;
                } else {
                    // Late bet - mark for refund
                    blueBet.isLateBet = true;
                    uint256 fee = (blueBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    lateFees += fee;
                }
            }
        }
        
        game.validRedPool = validRedPool;
        game.validBluePool = validBluePool;
        game.validLiquidity = validLiquidity;
        
        // Return late fees to gameBalance for refunds
        if (lateFees > 0) {
            gameFees[_gameId] -= lateFees;
            gameBalance[_gameId] += lateFees;
        }
    }
    
    /**
     * @notice Claim winnings from a resolved game
     * @param _gameId Game ID
     * @param _side Side to claim from
     */
    function claimWinnings(uint256 _gameId, Side _side) external nonReentrant {
        _claimWinnings(_gameId, _side);
    }
    
    /**
     * @notice Claim both sides at once
     */
    function claimAllWinnings(uint256 _gameId) external nonReentrant {
        SideBet storage redBet = sideBets[_gameId][msg.sender][Side.Red];
        SideBet storage blueBet = sideBets[_gameId][msg.sender][Side.Blue];
        
        if (redBet.amount > 0 && !redBet.claimed) {
            _claimWinnings(_gameId, Side.Red);
        }
        if (blueBet.amount > 0 && !blueBet.claimed) {
            _claimWinnings(_gameId, Side.Blue);
        }
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    function _claimWinnings(uint256 _gameId, Side _side) internal {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        SideBet storage bet = sideBets[_gameId][msg.sender][_side];
        
        if (bet.amount == 0) revert NoBetToClaim();
        if (bet.claimed) revert AlreadyClaimed();
        
        uint256 payout = 0;
        
        // Handle cancelled games - full refund (all bets)
        // _cancelGame() has already moved all gameFees into gameBalance, so gameBalance holds full bet amounts
        if (!game.hasWinner && game.phase == GamePhase.Finalized) {
            payout = bet.amount;
            if (gameBalance[_gameId] < payout) revert InsufficientGameBalance();
            bet.claimed = true;
            gameBalance[_gameId] -= payout;

            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();

            emit RefundClaimed(_gameId, msg.sender, _side, payout);
            return;
        }
        
        if (game.phase != GamePhase.Resolved && game.phase != GamePhase.Finalized) {
            revert GameNotResolved();
        }
        
        // Handle LATE BETS - full refund (anti-sniping protection)
        // _calculateValidPools() already moved late bet fees from gameFees into gameBalance
        if (bet.isLateBet) {
            payout = bet.amount;
            if (gameBalance[_gameId] < payout) revert InsufficientGameBalance();
            bet.claimed = true;
            gameBalance[_gameId] -= payout;

            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();

            emit LateBetRefunded(_gameId, msg.sender, _side, payout);
            return;
        }
        
        // Valid bet on losing side gets nothing
        if (_side != game.winningSide) {
            bet.claimed = true;
            userStats[msg.sender].totalLosses++;
            return;
        }
        
        // Calculate winnings using VALID pools only
        uint256 winningPool = game.winningSide == Side.Red ? game.validRedPool : game.validBluePool;
        uint256 userShare = (bet.amount * 1e18) / winningPool;
        payout = (game.validLiquidity * userShare) / 1e18;
        
        bet.claimed = true;
        
        if (payout > 0) {
            gameBalance[_gameId] -= payout;
            
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();
        }
        
        userStats[msg.sender].totalWins++;
        userStats[msg.sender].totalWinnings += payout;
        
        _updateLeaderboard(msg.sender);
        
        emit WinningsClaimed(_gameId, msg.sender, _side, bet.amount, payout);
    }
    
    function _cancelGame(uint256 _gameId, string memory _reason) internal {
        Game storage game = games[_gameId];
        
        // Return fees to game balance for full refunds
        uint256 feesToReturn = gameFees[_gameId];
        gameBalance[_gameId] += feesToReturn;
        gameFees[_gameId] = 0;
        
        uint256 totalPool = game.redPool + game.bluePool;
        game.totalLiquidity = totalPool;
        game.phase = GamePhase.Finalized;
        game.hasWinner = false;
        
        emit GameCancelled(_gameId, _reason);
    }
    
    // ==================== CIRCUIT BREAKER ====================
    
    /**
     * @notice Permissionless circuit breaker to void compromised games
     * @dev Callable by anyone when randomness integrity is compromised:
     *      - Check A (Leak Detection): targetDrandRound exists before game ends
     *      - Check B (Time Timeout): block.timestamp > predictedDrandTimestamp (chain lagging)
     * @param _gameId Game to check and potentially void
     */
    function voidCompromisedGame(uint256 _gameId) external {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        
        // Can only void games that are still active (Betting or Calculating)
        if (game.phase != GamePhase.Betting && game.phase != GamePhase.Calculating) {
            revert GameAlreadyResolved();
        }
        
        bool isCompromised = false;
        string memory reason;
        
        // Check A (Leak Detection): If targetDrandRound pulse exists before game ends,
        // the randomness is already known and can be exploited
        if (game.phase == GamePhase.Betting && block.number < game.endBlock) {
            (bool pulseExists, ) = _getDrandRandomness(game.targetDrandRound);
            if (pulseExists) {
                isCompromised = true;
                reason = "Randomness leaked - drand pulse available before game end";
            }
        }
        
        // Check B (Time Timeout): Only if chain is meaningfully lagging (past predicted time + grace).
        // Grace period prevents voiding normal committed games (~9s gap at commit).
        if (!isCompromised && block.timestamp > game.predictedDrandTimestamp + CHAIN_LAG_GRACE_SECONDS) {
            isCompromised = true;
            reason = "Chain lagging behind real-time - randomness potentially compromised";
        }
        
        if (!isCompromised) {
            revert GameNotCompromised();
        }
        
        // Void the game - all bets refunded
        _cancelGame(_gameId, reason);
        emit GameVoided(_gameId, reason);
    }
    
    // ==================== EMERGENCY WITHDRAW ====================
    
    /**
     * @notice User-centric emergency withdrawal for stuck games
     * @dev Allows individual users to recover their funds if a game is stuck for > 7 days
     *      - Only callable after EMERGENCY_TIMEOUT (7 days) from game start
     *      - Only for games that are NOT resolved
     *      - Withdraws only the caller's funds
     *      - Protected against reentrancy
     * @param _gameId Game to withdraw from
     */
    function withdrawEmergency(uint256 _gameId) external nonReentrant {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        
        // Cannot emergency withdraw from resolved games (use claimWinnings instead)
        if (game.phase == GamePhase.Resolved || game.phase == GamePhase.Finalized) {
            revert GameAlreadyResolved();
        }
        
        // Check emergency timeout (7 days from game start)
        // Game start time ≈ predictedDrandTimestamp - game duration
        // So 7 days from start ≈ predictedDrandTimestamp - game duration + 7 days
        uint256 emergencyUnlockTime = game.predictedDrandTimestamp + EMERGENCY_TIMEOUT - (BETTING_BLOCKS * BLOCK_TIME_SECONDS);
        if (block.timestamp < emergencyUnlockTime) {
            revert EmergencyTimeoutNotReached();
        }
        
        // Get user's bets
        SideBet storage redBet = sideBets[_gameId][msg.sender][Side.Red];
        SideBet storage blueBet = sideBets[_gameId][msg.sender][Side.Blue];
        
        uint256 redAmount = redBet.amount;
        uint256 blueAmount = blueBet.amount;
        uint256 totalBetAmount = redAmount + blueAmount;
        
        if (totalBetAmount == 0) {
            revert NothingToWithdraw();
        }
        
        // Calculate the net refund (what's actually stored in gameBalance)
        // The fee was deducted when bet was placed, so we refund net amounts
        uint256 redNet = redAmount > 0 ? redAmount - ((redAmount * PLATFORM_FEE) / FEE_DENOMINATOR) : 0;
        uint256 blueNet = blueAmount > 0 ? blueAmount - ((blueAmount * PLATFORM_FEE) / FEE_DENOMINATOR) : 0;
        uint256 totalRefund = redNet + blueNet;
        
        // Also refund the fees from gameFees (pro-rata for this user)
        uint256 redFee = redAmount > 0 ? (redAmount * PLATFORM_FEE) / FEE_DENOMINATOR : 0;
        uint256 blueFee = blueAmount > 0 ? (blueAmount * PLATFORM_FEE) / FEE_DENOMINATOR : 0;
        uint256 userFees = redFee + blueFee;
        
        // Zero out bet structs BEFORE transfer (reentrancy protection)
        if (redAmount > 0) {
            redBet.amount = 0;
            redBet.claimed = true;
        }
        if (blueAmount > 0) {
            blueBet.amount = 0;
            blueBet.claimed = true;
        }
        
        // Update balances - require full fee refund to be available (no silent partial loss)
        if (userFees > 0 && gameFees[_gameId] < userFees) {
            revert InsufficientFeesForRefund();
        }
        gameBalance[_gameId] -= totalRefund;
        if (userFees > 0) {
            gameFees[_gameId] -= userFees;
            totalRefund += userFees;
        }

        // Transfer funds
        (bool success, ) = payable(msg.sender).call{value: totalRefund}("");
        if (!success) revert TransferFailed();
        
        emit EmergencyWithdraw(_gameId, msg.sender, redAmount, blueAmount);
    }
    
    // ==================== DRAND HELPER FUNCTIONS ====================
    // Bittensor EVM uses address 0x09 for Bn128Add (not EIP-152 blake2f), so we compute
    // blake2b-128 in pure Solidity for Substrate Blake2_128Concat storage keys.

    /**
     * @notice BLAKE2b-128 (16-byte output) for 8-byte input. Pure Solidity; no precompile.
     * @dev Matches Substrate Blake2_128Concat hasher for u64 key. Used to build drand.pulses(round) storage key.
     * @param data Exactly 8 bytes (u64 little-endian)
     * @return hash 16-byte blake2b-128 hash
     */
    function _blake2b128(bytes memory data) internal pure returns (bytes16 hash) {
        require(data.length == 8, "blake2b128: need 8 bytes");
        // BLAKE2b IV (first 8 words, little-endian)
        uint64[8] memory h = [
            uint64(0x6a09e667f3bcc908) ^ 0x01010010, // digest_len=16, key_len=0
            uint64(0xbb67ae8584caa73b),
            uint64(0x3c6ef372fe94f82b),
            uint64(0xa54ff53a5f1d36f1),
            uint64(0x510e527fade682d1),
            uint64(0x9b05688c2b3e6c1f),
            uint64(0x1f83d9abfb41bd6b),
            uint64(0x5be0cd19137e2179)
        ];
        uint64[16] memory m;
        m[0] = uint64(uint8(data[0])) | (uint64(uint8(data[1])) << 8) | (uint64(uint8(data[2])) << 16) | (uint64(uint8(data[3])) << 24)
            | (uint64(uint8(data[4])) << 32) | (uint64(uint8(data[5])) << 40) | (uint64(uint8(data[6])) << 48) | (uint64(uint8(data[7])) << 56);
        // m[1..15] = 0
        uint64 t0 = 8;
        uint64 t1 = 0;
        uint64 f = 0xffffffffffffffff; // final block
        (h, ) = _blake2bCompress(h, m, t0, t1, f);
        // Build 16-byte output: h[0] LE (8 bytes) || h[1] LE (8 bytes)
        bytes memory out16 = new bytes(16);
        for (uint256 i = 0; i < 8; i++) {
            out16[i] = bytes1(uint8((h[0] >> (i * 8)) & 0xff));
            out16[8 + i] = bytes1(uint8((h[1] >> (i * 8)) & 0xff));
        }
        assembly ("memory-safe") {
            hash := mload(add(out16, 32))
        }
        return hash;
    }

    function _blake2bCompress(
        uint64[8] memory h,
        uint64[16] memory m,
        uint64 t0,
        uint64 t1,
        uint64 f
    ) internal pure returns (uint64[8] memory out, uint64[16] memory) {
        uint64[16] memory v;
        for (uint256 i = 0; i < 8; i++) v[i] = h[i];
        v[8] = 0x6a09e667f3bcc908;
        v[9] = 0xbb67ae8584caa73b;
        v[10] = 0x3c6ef372fe94f82b;
        v[11] = 0xa54ff53a5f1d36f1;
        v[12] = 0x510e527fade682d1 ^ t0;
        v[13] = 0x9b05688c2b3e6c1f ^ t1;
        v[14] = 0x1f83d9abfb41bd6b ^ f;
        v[15] = 0x5be0cd19137e2179;
        for (uint256 r = 0; r < 12; r++) {
            uint256[16] memory s = _blake2bSigma(r);
            _g(v, m, s[0], s[1], 0, 4, 8, 12);
            _g(v, m, s[2], s[3], 1, 5, 9, 13);
            _g(v, m, s[4], s[5], 2, 6, 10, 14);
            _g(v, m, s[6], s[7], 3, 7, 11, 15);
            _g(v, m, s[8], s[9], 0, 5, 10, 15);
            _g(v, m, s[10], s[11], 1, 6, 11, 12);
            _g(v, m, s[12], s[13], 2, 7, 8, 13);
            _g(v, m, s[14], s[15], 3, 4, 9, 14);
        }
        unchecked {
            for (uint256 i = 0; i < 8; i++) out[i] = h[i] ^ v[i] ^ v[i + 8];
        }
        return (out, m);
    }

    function _g(uint64[16] memory v, uint64[16] memory m, uint256 a, uint256 b, uint256 i, uint256 j, uint256 k, uint256 l) private pure {
        unchecked {
            v[i] = v[i] + v[j] + m[a];
            v[l] = _rotr64(v[l] ^ v[i], 32);
            v[k] = v[k] + v[l];
            v[j] = _rotr64(v[j] ^ v[k], 24);
            v[i] = v[i] + v[j] + m[b];
            v[l] = _rotr64(v[l] ^ v[i], 16);
            v[k] = v[k] + v[l];
            v[j] = _rotr64(v[j] ^ v[k], 63);
        }
    }

    function _rotr64(uint64 x, uint256 n) private pure returns (uint64) {
        uint64 n64 = uint64(n);
        return (x >> n64) | (x << (64 - n64));
    }

    function _blake2bSigma(uint256 r) private pure returns (uint256[16] memory s) {
        uint8[16][12] memory sigma = [
            [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
            [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
            [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
            [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
            [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
            [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
            [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
            [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
            [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
            [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
            [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4]
        ];
        for (uint256 i = 0; i < 16; i++) s[i] = sigma[r][i];
    }
    
    /**
     * @notice Build storage key for drand.pulses(round) using Blake2_128Concat
     * @param round The drand round number
     * @return key The full storage key
     */
    function _buildDrandPulseKey(uint64 round) internal pure returns (bytes memory) {
        // Encode round as u64 little-endian
        bytes memory roundLE = new bytes(8);
        uint64 r = round;
        for (uint256 i = 0; i < 8; i++) {
            roundLE[i] = bytes1(uint8(r));
            r = r >> 8;
        }
        
        // Blake2_128Concat = blake2_128(encoded_key) ++ encoded_key
        bytes16 hash = _blake2b128(roundLE);
        
        // Full key = prefix (32 bytes) + hash (16 bytes) + round (8 bytes) = 56 bytes
        bytes memory key = new bytes(56);
        
        // Copy prefix
        bytes memory prefix = DRAND_PULSES_PREFIX;
        for (uint256 i = 0; i < 32; i++) {
            key[i] = prefix[i];
        }
        
        // Copy blake2 hash
        for (uint256 i = 0; i < 16; i++) {
            key[32 + i] = hash[i];
        }
        
        // Copy round (little-endian)
        for (uint256 i = 0; i < 8; i++) {
            key[48 + i] = roundLE[i];
        }
        
        return key;
    }
    
    /**
     * @notice Read a value from Substrate storage using the precompile
     * @param key The storage key
     * @return data The stored value (empty if not found)
     */
    function _readSubstrateStorage(bytes memory key) internal view returns (bytes memory) {
        (bool success, bytes memory result) = STORAGE_PRECOMPILE.staticcall(key);
        if (!success) {
            return new bytes(0);
        }
        return result;
    }
    
    /**
     * @notice Get the last stored drand round from storage
     * @return round The last stored round (0 if not available)
     */
    function _getLastStoredRound() internal view returns (uint64) {
        bytes memory key = new bytes(32);
        bytes32 k = DRAND_LAST_ROUND_KEY;
        assembly ("memory-safe") {
            mstore(add(key, 32), k)
        }
        
        bytes memory data = _readSubstrateStorage(key);
        if (data.length < 8) {
            return 0;
        }
        
        // Decode u64 little-endian
        uint64 round = 0;
        for (uint256 i = 0; i < 8; i++) {
            round |= uint64(uint8(data[i])) << uint64(i * 8);
        }
        return round;
    }
    
    /**
     * @notice Read a drand pulse and extract the randomness
     * @dev Returns (exists, randomness) tuple to avoid sentinel value bug
     *      where bytes32(0) could be valid randomness (probability 2^-256)
     * @param round The drand round to read
     * @return exists True if pulse was found and decoded successfully
     * @return randomness The 32-byte randomness (valid only if exists==true)
     */
    function _getDrandRandomness(uint64 round) internal view returns (bool exists, bytes32 randomness) {
        bytes memory key = _buildDrandPulseKey(round);
        bytes memory data = _readSubstrateStorage(key);
        
        // Storage returns empty bytes when key doesn't exist
        if (data.length == 0) {
            return (false, bytes32(0));
        }
        
        // Decode SCALE-encoded Pulse:
        // - round: u64 (8 bytes LE)
        // - randomness: BoundedVec<u8, 32> (compact length + up to 32 bytes)
        // - signature: BoundedVec<u8, 144> (compact length + up to 144 bytes)
        
        // We need at least: 8 (round) + 1 (compact len) + 32 (randomness) = 41 bytes
        if (data.length < 41) {
            return (false, bytes32(0));
        }
        
        // Skip round (bytes 0-7)
        // Read compact length at byte 8
        uint8 compactLen = uint8(data[8]);
        
        // SCALE compact encoding:
        // Mode 0 (single byte): bits [7:2] = value, bits [1:0] = 00. Range: 0-63
        // Mode 1 (two bytes): bits [15:2] = value, bits [1:0] = 01. Range: 64-16383
        // For 32: 32 << 2 = 128 = 0x80, low 2 bits = 00, so value = 0x80 >> 2 = 32
        
        // Decode compact length
        uint256 randomnessLen;
        uint256 randomnessStart;
        
        if ((compactLen & 0x03) == 0) {
            // Single byte mode
            randomnessLen = compactLen >> 2;
            randomnessStart = 9;
        } else if ((compactLen & 0x03) == 1) {
            // Two byte mode
            if (data.length < 10) return (false, bytes32(0));
            uint16 val = uint16(compactLen) | (uint16(uint8(data[9])) << 8);
            randomnessLen = val >> 2;
            randomnessStart = 10;
        } else {
            // Four byte or big integer mode - randomness shouldn't need this
            return (false, bytes32(0));
        }
        
        // Validate length - randomness must be exactly 32 bytes
        if (randomnessLen != 32) {
            return (false, bytes32(0));
        }
        
        if (data.length < randomnessStart + 32) {
            return (false, bytes32(0));
        }
        
        // Extract 32-byte randomness
        bytes32 rand;
        assembly ("memory-safe") {
            rand := mload(add(add(data, 32), randomnessStart))
        }
        
        // Pulse exists and was decoded successfully
        // randomness can be any value including bytes32(0)
        return (true, rand);
    }
    
    function _updateLeaderboard(address _user) internal {
        uint256 userWinnings = userStats[_user].totalWinnings;
        
        bool found = false;
        uint256 userIndex = 0;
        
        for (uint256 i = 0; i < leaderboard.length; i++) {
            if (leaderboard[i] == _user) {
                found = true;
                userIndex = i;
                break;
            }
        }
        
        if (!found) {
            if (leaderboard.length < MAX_LEADERBOARD_SIZE) {
                leaderboard.push(_user);
                userIndex = leaderboard.length - 1;
            } else {
                uint256 lowestWinnings = userStats[leaderboard[leaderboard.length - 1]].totalWinnings;
                if (userWinnings > lowestWinnings) {
                    leaderboard[leaderboard.length - 1] = _user;
                    userIndex = leaderboard.length - 1;
                } else {
                    return;
                }
            }
        }
        
        while (userIndex > 0 && userStats[leaderboard[userIndex]].totalWinnings > userStats[leaderboard[userIndex - 1]].totalWinnings) {
            address temp = leaderboard[userIndex - 1];
            leaderboard[userIndex - 1] = leaderboard[userIndex];
            leaderboard[userIndex] = temp;
            userIndex--;
        }
    }

    // ==================== VIEW FUNCTIONS ====================
    
    function getGame(uint256 _gameId) external view returns (Game memory) {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        return games[_gameId];
    }
    
    function getCurrentGame() external view returns (Game memory) {
        if (currentGameId == 0) revert NoActiveGame();
        return games[currentGameId];
    }
    
    function getUserSideBet(uint256 _gameId, address _user, Side _side) external view returns (SideBet memory) {
        return sideBets[_gameId][_user][_side];
    }
    
    function getUserBets(uint256 _gameId, address _user) external view returns (UserBets memory) {
        return UserBets({
            redBet: sideBets[_gameId][_user][Side.Red],
            blueBet: sideBets[_gameId][_user][Side.Blue]
        });
    }
    
    function getUserStats(address _user) external view returns (UserStats memory) {
        return userStats[_user];
    }
    
    function getLeaderboard() external view returns (address[] memory) {
        return leaderboard;
    }
    
    function getLeaderboardWithStats(uint256 _limit) external view returns (
        address[] memory addresses,
        uint256[] memory winnings,
        uint256[] memory wins
    ) {
        uint256 count = _limit < leaderboard.length ? _limit : leaderboard.length;
        addresses = new address[](count);
        winnings = new uint256[](count);
        wins = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            addresses[i] = leaderboard[i];
            winnings[i] = userStats[leaderboard[i]].totalWinnings;
            wins[i] = userStats[leaderboard[i]].totalWins;
        }
    }
    
    function calculatePotentialPayout(
        uint256 _gameId,
        address _user,
        Side _side, 
        uint256 _amount
    ) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 0;
        
        Game storage game = games[_gameId];
        
        uint256 existingBet = sideBets[_gameId][_user][_side].amount;
        uint256 totalUserBet = existingBet + _amount;
        
        uint256 feeAmount = (_amount * PLATFORM_FEE) / FEE_DENOMINATOR;
        uint256 netNewAmount = _amount - feeAmount;
        
        uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
        uint256 newSidePool = sidePool + _amount;
        uint256 newTotalLiquidity = game.totalLiquidity + netNewAmount;
        
        return (totalUserBet * newTotalLiquidity) / newSidePool;
    }
    
    function getCurrentMultiplier(uint256 _gameId, Side _side) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 10000;
        
        Game storage game = games[_gameId];
        
        uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
        if (sidePool == 0) return 0;
        
        return (game.totalLiquidity * 10000) / sidePool;
    }
    
    function getBlocksRemaining(uint256 _gameId) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 0;
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) return 0;
        if (block.number >= game.endBlock) return 0;
        
        return game.endBlock - block.number;
    }
    
    function isInFinalCall(uint256 _gameId) external view returns (bool) {
        if (_gameId == 0 || _gameId >= nextGameId) return false;
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) return false;
        
        uint256 finalCallStartBlock = game.endBlock - FINAL_CALL_BLOCKS;
        return block.number >= finalCallStartBlock && block.number < game.endBlock;
    }
    
    function getGameCount() external view returns (uint256) {
        return nextGameId - 1;
    }
    
    function getGameBettors(uint256 _gameId) external view returns (address[] memory) {
        return gameBettors[_gameId];
    }
    
    function getGameBalance(uint256 _gameId) external view returns (uint256) {
        return gameBalance[_gameId];
    }
    
    function getGameFees(uint256 _gameId) external view returns (uint256) {
        return gameFees[_gameId];
    }
    
    /**
     * @notice Get anti-sniping resolution status (drand-based)
     * @return phase Current game phase
     * @return targetDrandRound Drand round committed to for randomness
     * @return actualEndBlock The randomly selected end block (0 if not yet determined)
     * @return canFinalize True if phase 2 can be called (drand pulse available)
     */
    function getResolutionStatus(uint256 _gameId) external view returns (
        GamePhase phase,
        uint64 targetDrandRound,
        uint256 actualEndBlock,
        bool canFinalize
    ) {
        Game storage game = games[_gameId];
        phase = game.phase;
        targetDrandRound = game.targetDrandRound;
        actualEndBlock = game.actualEndBlock;
        canFinalize = false;
        
        if (game.phase == GamePhase.Calculating && game.targetDrandRound > 0) {
            (bool pulseExists, ) = _getDrandRandomness(game.targetDrandRound);
            canFinalize = pulseExists;
        }
    }
    
    /**
     * @notice Check if a game is compromised (chain lagging behind real-time)
     * @dev Uses time-based check: block.timestamp > predictedDrandTimestamp + CHAIN_LAG_GRACE_SECONDS
     */
    function isGameCompromised(uint256 _gameId) external view returns (bool) {
        Game storage game = games[_gameId];
        if (game.phase != GamePhase.Betting && game.phase != GamePhase.Calculating) return false;
        
        // Check if chain is meaningfully lagging (past predicted time + grace period)
        if (block.timestamp > game.predictedDrandTimestamp + CHAIN_LAG_GRACE_SECONDS) return true;
        
        // Check if randomness is already leaked (drand pulse available before game ends)
        if (game.phase == GamePhase.Betting && block.number < game.endBlock) {
            (bool pulseExists, ) = _getDrandRandomness(game.targetDrandRound);
            if (pulseExists) return true;
        }
        
        return false;
    }
    
    /**
     * @notice Check if a specific bet was marked as late (for anti-sniping)
     */
    function isBetLate(uint256 _gameId, address _user, Side _side) external view returns (bool) {
        return sideBets[_gameId][_user][_side].isLateBet;
    }
    
    // ==================== DRAND VIEW FUNCTIONS ====================
    
    /**
     * @notice Get the last stored drand round from the chain
     * @return round The last available drand round (0 if drand not available)
     */
    function getLastDrandRound() external view returns (uint64) {
        return _getLastStoredRound();
    }
    
    /**
     * @notice Check if a specific drand round's pulse is available
     * @param round The drand round to check
     * @return available True if the pulse is stored and readable
     */
    function isDrandRoundAvailable(uint64 round) external view returns (bool) {
        (bool exists, ) = _getDrandRandomness(round);
        return exists;
    }
    
    /**
     * @notice Get randomness from a specific drand round (for debugging)
     * @param round The drand round
     * @return exists True if pulse was found
     * @return randomness The 32-byte randomness (valid only if exists==true)
     */
    function getDrandRandomness(uint64 round) external view returns (bool exists, bytes32 randomness) {
        return _getDrandRandomness(round);
    }
    
    /**
     * @notice Check drand health - returns info about drand availability
     * @return lastRound The last stored drand round
     * @return isAvailable True if drand storage is accessible
     */
    function getDrandStatus() external view returns (uint64 lastRound, bool isAvailable) {
        lastRound = _getLastStoredRound();
        isAvailable = lastRound > 0;
    }

    // ==================== OWNER FUNCTIONS ====================
    
    /**
     * @notice Withdraw accumulated platform fees (only from resolved games)
     * @dev Owner can ONLY withdraw fees - cannot affect active games or user funds
     */
    function withdrawFees() external onlyOwner {
        uint256 fees = accumulatedFees;
        if (fees > 0) {
            accumulatedFees = 0;
            
            (bool success, ) = payable(owner()).call{value: fees}("");
            if (!success) revert TransferFailed();
        }
    }
    
    /**
     * @notice Get accumulated platform fees available for withdrawal
     */
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
}
