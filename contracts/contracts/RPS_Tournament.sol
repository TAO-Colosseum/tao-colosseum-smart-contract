// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title RPS_Tournament
 * @notice Single-elimination Rock-Paper-Scissors tournament on Bittensor EVM.
 * @dev Hash commit-reveal + drand fallback (no chain changes required):
 *      - Commit: keccak256(abi.encode(tournamentId, round, matchIndex, rpsRound, player, uint8(choice), salt))
 *      - Reveal: player submits (choice, salt)
 *      - Resolve: permissionless after reveal window; unrevealed => lose
 *      - Tie handling: replay up to maxRPSRoundsPerMatch, then drand tiebreak
 *
 * Liveness: EVM can't run automatically, so a tx must resolve matches. `tryRevealMatch` is permissionless.
 */
contract RPS_Tournament is ReentrancyGuard {

    // ==================== ENUMS ====================

    enum TournamentPhase {
        Registration,
        Active,
        Canceled,
        Completed
    }

    enum RPSChoice {
        None,
        Rock,
        Paper,
        Scissors
    }

    // ==================== STRUCTS ====================

    struct TournamentConfig {
        uint8 maxPlayers;   // 4, 8, or 16
        uint256 maxRegBlocks; // blocks from create
        uint256 minEntry;   // wei
        uint256 commitBlocks;
        uint256 revealBlocks;
        uint8 maxRPSRoundsPerMatch;
    }

    struct Tournament {
        uint256 id;
        TournamentPhase phase;
        address creator;
        uint256 registrationEndBlock;
        uint256 prizePool;
        uint256 currentRound;
        uint256 roundStartBlock;
        address winner;
        bool prizeClaimed;
    }

    struct Match {
        address playerA;
        address playerB;
        uint256 commitEndBlock;
        uint256 revealEndBlock;
        uint8 rpsRound; // 0..maxRPSRoundsPerMatch-1
        uint64 seedRound; // drand round selected for tie/no-show of the CURRENT rpsRound
        address winner; // set when resolved
    }

    // ==================== CONSTANTS ====================

    uint256 public constant MIN_ENTRY = 0.5 ether;
    uint256 public constant STALL_BLOCKS = 1000;
    uint256 public constant MAX_REG_BLOCKS = 50;

    // Fixed tournament parameters (best-practice: avoid footguns / adversarial configs)
    uint256 public constant COMMIT_BLOCKS = 10;
    uint256 public constant REVEAL_BLOCKS = 10;
    uint8 public constant MAX_RPS_ROUNDS_PER_MATCH = 3;

    // Fixed buffer: match ties/no-shows resolve using randomness from a future drand round.
    // Must be large enough that the pulse is very likely available by the time resolution is attempted.
    uint64 public constant SEED_ROUND_BUFFER_ROUNDS = 20;

    // Drand via storage precompile (same as TAO_Colosseum): 0x0807 = StorageQuery, fallback for pulses
    address public constant STORAGE_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    // Drand precompile (subtensor PR #2445): 0x080e = 2062
    address public constant DRAND_PRECOMPILE  = 0x000000000000000000000000000000000000080e;

    bytes public constant DRAND_PULSES_PREFIX = hex"a285cdb66e8b8524ea70b1693c7b1e050d8e70fd32bfb1639703f9a23d15b15e";
    bytes32 public constant DRAND_LAST_ROUND_KEY = 0xa285cdb66e8b8524ea70b1693c7b1e05087f3dd6e0ceded0e388dd34f810a73d;

    // ==================== CUSTOM ERRORS ====================

    error TournamentNotFound();
    error InvalidMaxPlayers();
    error InvalidMinEntry();
    error InvalidCommitOrRevealBlocks();
    error InvalidConfig();
    error InvalidMaxRegBlocks();
    error NotRegistrationPhase();
    error RegistrationEnded();
    error AlreadyRegistered();
    error TournamentFull();
    error InsufficientEntry();
    error CannotStart();
    error CannotCancel();
    error NotActive();
    error NotYourMatch();
    error CommitPhaseEnded();
    error RevealPhaseNotStarted();
    error RevealPhaseEnded();
    error InvalidCommitHash();
    error MatchAlreadyResolved();
    error InvalidChoice();
    error NotCompleted();
    error NotWinner();
    error PrizeAlreadyClaimed();
    error TransferFailed();
    error DrandUnavailable();
    error InsufficientOrExcessEntry();
    error CommitAlreadySet();
    error NotCancelableYet();
    error InvalidRound();
    error InvalidMatchIndex();
    error MatchNotInitialized();
    error RevealPhaseNotEnded();
    error NotRegistered();
    error DirectETHNotAccepted();
    error SeedRoundAlreadyKnown();

    // ==================== STATE ====================

    uint256 public nextTournamentId = 1;

    mapping(uint256 => Tournament) public tournaments;
    mapping(uint256 => TournamentConfig) public tournamentConfig;
    mapping(uint256 => address[]) public tournamentPlayers;
    mapping(uint256 => address[]) public tournamentAdvancingPlayers;
    mapping(uint256 => mapping(uint256 => address)) public tournamentByePlayer;
    mapping(uint256 => mapping(uint256 => uint256)) public tournamentMatchCount;

    mapping(uint256 => mapping(uint256 => mapping(uint256 => Match))) public matches;
    /// Commit = keccak256(abi.encode(tournamentId, round, matchIndex, rpsRound, player, uint8(choice), salt))
    mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(address => bytes32))))) public commitHash;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(address => RPSChoice))))) public revealedChoice;

    /// Pull-based refunds (avoid refund-loop DoS).
    mapping(address => uint256) public pendingWithdrawals;

    // ==================== EVENTS ====================

    event TournamentCreated(uint256 indexed tournamentId, address creator, uint8 maxPlayers, uint256 minEntry, uint256 registrationEndBlock);
    event PlayerRegistered(uint256 indexed tournamentId, address player, uint256 entry);
    event TournamentStarted(uint256 indexed tournamentId, uint256 playerCount);
    event TournamentCanceled(uint256 indexed tournamentId);
    event MatchCreated(uint256 indexed tournamentId, uint256 round, uint256 matchIndex, address playerA, address playerB);
    event MoveCommitted(uint256 indexed tournamentId, uint256 round, uint256 matchIndex, uint8 rpsRound, address player, bytes32 commitHash);
    event MoveRevealed(uint256 indexed tournamentId, uint256 round, uint256 matchIndex, uint8 rpsRound, address player, RPSChoice choice);
    event MatchResolved(uint256 indexed tournamentId, uint256 round, uint256 matchIndex, uint8 rpsRound, address winner);
    event MatchReplayed(uint256 indexed tournamentId, uint256 round, uint256 matchIndex, uint8 newRpsRound, uint256 commitEndBlock, uint256 revealEndBlock);
    event RoundAdvanced(uint256 indexed tournamentId, uint256 newRound);
    event TournamentCompleted(uint256 indexed tournamentId, address winner);
    event PrizeClaimed(uint256 indexed tournamentId, address winner, uint256 amount);
    event WithdrawalAccrued(address indexed to, uint256 amount);

    // ==================== CONSTRUCTOR ====================

    constructor() {}

    // ==================== PHASE 2: LIFECYCLE ====================

    /**
     * @notice Create a new tournament. maxPlayers must be 4, 8, or 16.
     */
    function createTournament(
        uint8 _maxPlayers,
        uint256 _maxRegBlocks,
        uint256 _minEntry
    ) external returns (uint256 tournamentId) {
        return _createTournament(_maxPlayers, _maxRegBlocks, _minEntry);
    }

    /**
     * @notice Backward-compatible create function with fixed config arguments.
     * @dev Prefer the 3-arg overload; this exists so older callers can keep working.
     */
    function createTournament(
        uint8 _maxPlayers,
        uint256 _maxRegBlocks,
        uint256 _minEntry,
        uint256 _commitBlocks,
        uint256 _revealBlocks,
        uint8 _maxRPSRoundsPerMatch
    ) external returns (uint256 tournamentId) {
        if (_commitBlocks != COMMIT_BLOCKS || _revealBlocks != REVEAL_BLOCKS) revert InvalidCommitOrRevealBlocks();
        if (_maxRPSRoundsPerMatch != MAX_RPS_ROUNDS_PER_MATCH) revert InvalidConfig();
        return _createTournament(_maxPlayers, _maxRegBlocks, _minEntry);
    }

    function _createTournament(
        uint8 _maxPlayers,
        uint256 _maxRegBlocks,
        uint256 _minEntry
    ) internal returns (uint256 tournamentId) {
        if (_maxPlayers != 4 && _maxPlayers != 8 && _maxPlayers != 16) revert InvalidMaxPlayers();
        if (_maxRegBlocks == 0 || _maxRegBlocks > MAX_REG_BLOCKS) revert InvalidMaxRegBlocks();
        if (_minEntry < MIN_ENTRY) revert InvalidMinEntry();

        tournamentId = nextTournamentId++;
        uint256 regEndBlock = block.number + _maxRegBlocks;

        tournaments[tournamentId] = Tournament({
            id: tournamentId,
            phase: TournamentPhase.Registration,
            creator: msg.sender,
            registrationEndBlock: regEndBlock,
            prizePool: 0,
            currentRound: 0,
            roundStartBlock: 0,
            winner: address(0),
            prizeClaimed: false
        });

        tournamentConfig[tournamentId] = TournamentConfig({
            maxPlayers: _maxPlayers,
            maxRegBlocks: _maxRegBlocks,
            minEntry: _minEntry,
            commitBlocks: COMMIT_BLOCKS,
            revealBlocks: REVEAL_BLOCKS,
            maxRPSRoundsPerMatch: MAX_RPS_ROUNDS_PER_MATCH
        });

        emit TournamentCreated(tournamentId, msg.sender, _maxPlayers, _minEntry, regEndBlock);
        return tournamentId;
    }

    /**
     * @notice Register for a tournament. Must pay minEntry before registrationEndBlock.
     */
    function register(uint256 _tournamentId) external payable nonReentrant {
        Tournament storage t = tournaments[_tournamentId];
        if (t.id == 0) revert TournamentNotFound();
        if (t.phase != TournamentPhase.Registration) revert NotRegistrationPhase();
        if (block.number >= t.registrationEndBlock) revert RegistrationEnded();

        address[] storage players = tournamentPlayers[_tournamentId];
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == msg.sender) revert AlreadyRegistered();
        }
        if (players.length >= tournamentConfig[_tournamentId].maxPlayers) revert TournamentFull();
        // enforce exact entry to guarantee consistent refunds and avoid trapping excess funds
        if (msg.value != tournamentConfig[_tournamentId].minEntry) revert InsufficientOrExcessEntry();

        players.push(msg.sender);
        t.prizePool += msg.value;
        emit PlayerRegistered(_tournamentId, msg.sender, msg.value);
    }

    /**
     * @notice Unregister during Registration and pull your entry back.
     * @dev Pull-based refunds to avoid refund-loop DoS.
     */
    function unregister(uint256 _tournamentId) external nonReentrant {
        Tournament storage t = tournaments[_tournamentId];
        if (t.id == 0) revert TournamentNotFound();
        if (t.phase != TournamentPhase.Registration) revert NotRegistrationPhase();
        if (block.number >= t.registrationEndBlock) revert RegistrationEnded();

        address[] storage players = tournamentPlayers[_tournamentId];
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == msg.sender) { idx = i; break; }
        }
        if (idx == type(uint256).max) revert NotRegistered();

        // swap-pop
        uint256 last = players.length - 1;
        if (idx != last) players[idx] = players[last];
        players.pop();

        uint256 amt = tournamentConfig[_tournamentId].minEntry;
        pendingWithdrawals[msg.sender] += amt;
        emit WithdrawalAccrued(msg.sender, amt);
        t.prizePool -= amt;
    }

    /**
     * @notice Start the tournament. Callable by anyone when slots full or time's up with >= 2 players.
     */
    function startTournament(uint256 _tournamentId) external {
        Tournament storage t = tournaments[_tournamentId];
        if (t.id == 0) revert TournamentNotFound();
        if (t.phase != TournamentPhase.Registration) revert NotRegistrationPhase();

        address[] storage players = tournamentPlayers[_tournamentId];
        uint8 maxPlayers = tournamentConfig[_tournamentId].maxPlayers;
        bool full = players.length == maxPlayers;
        bool timeUpAndEnough = block.number >= t.registrationEndBlock && players.length >= 2;
        if (!full && !timeUpAndEnough) revert CannotStart();

        t.phase = TournamentPhase.Active;
        t.roundStartBlock = block.number;
        _initBracket(_tournamentId);
        emit TournamentStarted(_tournamentId, players.length);
    }

    /**
     * @notice Cancel tournament and refund all. Callable when registration ended and < 2 players.
     */
    function cancelTournament(uint256 _tournamentId) external nonReentrant {
        Tournament storage t = tournaments[_tournamentId];
        if (t.id == 0) revert TournamentNotFound();
        if (t.phase != TournamentPhase.Registration) revert NotRegistrationPhase();
        if (block.number < t.registrationEndBlock) revert CannotCancel();
        address[] storage players = tournamentPlayers[_tournamentId];
        if (players.length >= 2) revert CannotCancel();

        t.phase = TournamentPhase.Canceled;
        for (uint256 i = 0; i < players.length; i++) {
            uint256 amt = tournamentConfig[_tournamentId].minEntry;
            pendingWithdrawals[players[i]] += amt;
            emit WithdrawalAccrued(players[i], amt);
        }
        t.prizePool = 0;
        emit TournamentCanceled(_tournamentId);
    }

    // ==================== BRACKET INIT (INTERNAL) ====================

    function _initBracket(uint256 _tournamentId) internal {
        address[] storage players = tournamentPlayers[_tournamentId];
        uint256 n = players.length;
        if (n == 0) return;

        uint64 lastRound = _getLastStoredRound();
        if (lastRound == 0) revert DrandUnavailable();
        (bool hasRandomness, bytes32 seed) = _getDrandRandomness(lastRound);
        if (!hasRandomness) revert DrandUnavailable();

        // Fisher–Yates shuffle with drand
        for (uint256 i = 0; i < n; i++) {
            uint256 j = i + (uint256(seed) % (n - i));
            (uint256 ji, uint256 jj) = (j, i);
            address tmp = players[ji];
            players[ji] = players[jj];
            players[jj] = tmp;
            seed = keccak256(abi.encodePacked(seed, i, j));
        }

        tournamentAdvancingPlayers[_tournamentId] = players;
        _createRoundMatches(_tournamentId, 0);
    }

    function _createRoundMatches(uint256 _tournamentId, uint256 _round) internal {
        address[] storage advancing = tournamentAdvancingPlayers[_tournamentId];
        uint256 n = advancing.length;
        if (n == 0) return;

        TournamentConfig storage cfg = tournamentConfig[_tournamentId];
        uint256 commitEnd = block.number + cfg.commitBlocks;
        uint256 revealEnd = commitEnd + cfg.revealBlocks;

        uint64 lastRound = _getLastStoredRound();
        if (lastRound == 0) revert DrandUnavailable();
        uint64 seedRound = lastRound + SEED_ROUND_BUFFER_ROUNDS;

        if (n == 1) {
            tournaments[_tournamentId].winner = advancing[0];
            tournaments[_tournamentId].phase = TournamentPhase.Completed;
            emit TournamentCompleted(_tournamentId, advancing[0]);
            return;
        }

        (bool hasR, bytes32 baseRand) = _getDrandRandomness(lastRound);
        if (!hasR) revert DrandUnavailable();
        bytes32 r = keccak256(abi.encodePacked(baseRand, _tournamentId, _round, commitEnd, revealEnd));

        uint256 byeIndex = type(uint256).max;
        if (n % 2 == 1) {
            byeIndex = uint256(r) % n;
            tournamentByePlayer[_tournamentId][_round] = advancing[byeIndex];
        }

        // Pair consecutive indices, skipping bye. numMatches = n/2.
        uint256 numMatches = n / 2;
        uint256 createdMatches = 0;
        uint256 a = 0;
        uint256 b = 1;
        for (uint256 matchIndex = 0; matchIndex < numMatches; matchIndex++) {
            if (byeIndex != type(uint256).max) {
                if (a == byeIndex) a++;
                if (b == byeIndex) b++;
                if (a == b) b++;
            }
            if (a >= n || b >= n) break;
            matches[_tournamentId][_round][matchIndex] = Match({
                playerA: advancing[a],
                playerB: advancing[b],
                commitEndBlock: commitEnd,
                revealEndBlock: revealEnd,
                rpsRound: 0,
                seedRound: seedRound,
                winner: address(0)
            });
            emit MatchCreated(_tournamentId, _round, matchIndex, advancing[a], advancing[b]);
            createdMatches++;
            a = b + 1;
            b = a + 1;
        }
        tournamentMatchCount[_tournamentId][_round] = createdMatches;
    }

    // ==================== PHASE 3: COMMIT / REVEAL ====================

    /**
     * @notice Commit your move hash during commit window.
     * @dev commitHash = keccak256(abi.encode(tournamentId, round, matchIndex, rpsRound, player, uint8(choice), salt))
     */
    function commitMove(uint256 _tournamentId, uint256 _round, uint256 _matchIndex, bytes32 _commitHash) external {
        Tournament storage t = tournaments[_tournamentId];
        if (t.phase != TournamentPhase.Active) revert NotActive();
        if (_round != t.currentRound) revert InvalidRound();
        uint256 count = tournamentMatchCount[_tournamentId][_round];
        if (_matchIndex >= count) revert InvalidMatchIndex();
        Match storage m = matches[_tournamentId][_round][_matchIndex];
        if (m.playerA == address(0) || m.playerB == address(0)) revert MatchNotInitialized();
        if (m.winner != address(0)) revert MatchAlreadyResolved();
        if (msg.sender != m.playerA && msg.sender != m.playerB) revert NotYourMatch();
        if (block.number > m.commitEndBlock) revert CommitPhaseEnded();
        // Ensure tiebreak randomness for this sub-round is still unknown at commit time.
        // If the seed drand round is already stored, a player could deliberately force ties to reach a known tiebreak.
        uint64 lastRound = _getLastStoredRound();
        if (lastRound != 0 && lastRound >= m.seedRound) revert SeedRoundAlreadyKnown();
        if (_commitHash == bytes32(0)) revert InvalidCommitHash();
        uint256 rr = uint256(m.rpsRound);
        if (commitHash[_tournamentId][_round][_matchIndex][rr][msg.sender] != bytes32(0)) revert CommitAlreadySet();

        commitHash[_tournamentId][_round][_matchIndex][rr][msg.sender] = _commitHash;
        emit MoveCommitted(_tournamentId, _round, _matchIndex, m.rpsRound, msg.sender, _commitHash);
    }

    /**
     * @notice Reveal your move during reveal window.
     */
    function revealMove(uint256 _tournamentId, uint256 _round, uint256 _matchIndex, RPSChoice _choice, bytes32 _salt) external {
        Tournament storage t = tournaments[_tournamentId];
        if (t.phase != TournamentPhase.Active) revert NotActive();
        if (_round != t.currentRound) revert InvalidRound();
        uint256 count = tournamentMatchCount[_tournamentId][_round];
        if (_matchIndex >= count) revert InvalidMatchIndex();
        Match storage m = matches[_tournamentId][_round][_matchIndex];
        if (m.playerA == address(0) || m.playerB == address(0)) revert MatchNotInitialized();
        if (m.winner != address(0)) revert MatchAlreadyResolved();
        if (msg.sender != m.playerA && msg.sender != m.playerB) revert NotYourMatch();
        if (block.number <= m.commitEndBlock) revert RevealPhaseNotStarted();
        if (block.number > m.revealEndBlock) revert RevealPhaseEnded();
        if (_choice != RPSChoice.Rock && _choice != RPSChoice.Paper && _choice != RPSChoice.Scissors) revert InvalidChoice();

        uint256 rr = uint256(m.rpsRound);
        bytes32 committed = commitHash[_tournamentId][_round][_matchIndex][rr][msg.sender];
        if (committed == bytes32(0)) revert InvalidCommitHash();
        bytes32 expected = keccak256(abi.encode(_tournamentId, _round, _matchIndex, rr, msg.sender, uint8(_choice), _salt));
        if (committed != expected) revert InvalidCommitHash();

        revealedChoice[_tournamentId][_round][_matchIndex][rr][msg.sender] = _choice;
        emit MoveRevealed(_tournamentId, _round, _matchIndex, m.rpsRound, msg.sender, _choice);
    }

    // ==================== PHASE 4: RESOLVE ====================

    /**
     * @notice Resolve a match after reveal window. Callable by anyone.
     * @dev Unrevealed => lose; both unrevealed or tie => drand tiebreak.
     */
    function tryRevealMatch(uint256 _tournamentId, uint256 _round, uint256 _matchIndex) external nonReentrant {
        Tournament storage t = tournaments[_tournamentId];
        if (t.phase != TournamentPhase.Active) revert NotActive();
        if (_round != t.currentRound) revert InvalidRound();
        uint256 count = tournamentMatchCount[_tournamentId][_round];
        if (_matchIndex >= count) revert InvalidMatchIndex();
        Match storage m = matches[_tournamentId][_round][_matchIndex];
        if (m.playerA == address(0) || m.playerB == address(0)) revert MatchNotInitialized();
        if (m.winner != address(0)) revert MatchAlreadyResolved();
        if (block.number <= m.revealEndBlock) revert RevealPhaseNotEnded();

        TournamentConfig storage cfg = tournamentConfig[_tournamentId];
        uint256 rr = uint256(m.rpsRound);

        bool committedA = commitHash[_tournamentId][_round][_matchIndex][rr][m.playerA] != bytes32(0);
        bool committedB = commitHash[_tournamentId][_round][_matchIndex][rr][m.playerB] != bytes32(0);
        RPSChoice choiceA = revealedChoice[_tournamentId][_round][_matchIndex][rr][m.playerA];
        RPSChoice choiceB = revealedChoice[_tournamentId][_round][_matchIndex][rr][m.playerB];
        bool hasA = committedA && choiceA != RPSChoice.None;
        bool hasB = committedB && choiceB != RPSChoice.None;

        uint64 seedRound = m.seedRound;
        (bool drandOk, bytes32 rand) = _getDrandRandomness(seedRound);

        address winner_;
        if (!committedA && !committedB) {
            if (!drandOk) revert DrandUnavailable();
            winner_ = (uint256(rand) % 2 == 0) ? m.playerA : m.playerB;
        } else if (!committedA) {
            winner_ = m.playerB;
        } else if (!committedB) {
            winner_ = m.playerA;
        } else if (!hasA && !hasB) {
            if (!drandOk) revert DrandUnavailable();
            winner_ = (uint256(rand) % 2 == 0) ? m.playerA : m.playerB;
        } else if (!hasA) {
            winner_ = m.playerB;
        } else if (!hasB) {
            winner_ = m.playerA;
        } else {
            winner_ = _rpsWinner(choiceA, choiceB, m.playerA, m.playerB);
            if (winner_ == address(0)) {
                // Tie: replay up to maxRPSRoundsPerMatch, then drand tiebreak.
                if (m.rpsRound + 1 < cfg.maxRPSRoundsPerMatch) {
                    m.rpsRound += 1;
                    uint256 newCommitEnd = block.number + cfg.commitBlocks;
                    uint256 newRevealEnd = newCommitEnd + cfg.revealBlocks;
                    m.commitEndBlock = newCommitEnd;
                    m.revealEndBlock = newRevealEnd;
                    
                    // (Recomputing avoids having a long-running match reach a known seedRound.)
                    uint64 lastR = _getLastStoredRound();
                    if (lastR == 0) revert DrandUnavailable();
                    m.seedRound = lastR + SEED_ROUND_BUFFER_ROUNDS;

                    // progress marker to support stall detection
                    tournaments[_tournamentId].roundStartBlock = block.number;
                    emit MatchReplayed(_tournamentId, _round, _matchIndex, m.rpsRound, newCommitEnd, newRevealEnd);
                    return;
                }
                if (!drandOk) revert DrandUnavailable();
                winner_ = (uint256(rand) % 2 == 0) ? m.playerA : m.playerB;
            }
        }

        m.winner = winner_;
        emit MatchResolved(_tournamentId, _round, _matchIndex, m.rpsRound, winner_);
        // progress marker to support stall detection
        tournaments[_tournamentId].roundStartBlock = block.number;
        _checkRoundAdvance(_tournamentId, _round);
    }

    function _rpsWinner(RPSChoice a, RPSChoice b, address playerA, address playerB) internal pure returns (address) {
        if (a == b) return address(0);
        if (a == RPSChoice.Rock && b == RPSChoice.Scissors) return playerA;
        if (a == RPSChoice.Scissors && b == RPSChoice.Rock) return playerB;
        if (a == RPSChoice.Paper && b == RPSChoice.Rock) return playerA;
        if (a == RPSChoice.Rock && b == RPSChoice.Paper) return playerB;
        if (a == RPSChoice.Scissors && b == RPSChoice.Paper) return playerA;
        if (a == RPSChoice.Paper && b == RPSChoice.Scissors) return playerB;
        return address(0);
    }

    function _checkRoundAdvance(uint256 _tournamentId, uint256 _round) internal {
        if (_round != tournaments[_tournamentId].currentRound) return;
        uint256 count = tournamentMatchCount[_tournamentId][_round];
        if (count == 0) return;
        for (uint256 i = 0; i < count; i++) {
            if (matches[_tournamentId][_round][i].winner == address(0)) return;
        }
        address[] storage advancing = tournamentAdvancingPlayers[_tournamentId];
        while (advancing.length > 0) advancing.pop();
        for (uint256 i = 0; i < count; i++) {
            advancing.push(matches[_tournamentId][_round][i].winner);
        }
        address bye = tournamentByePlayer[_tournamentId][_round];
        if (bye != address(0)) advancing.push(bye);

        if (advancing.length == 1) {
            tournaments[_tournamentId].winner = advancing[0];
            tournaments[_tournamentId].phase = TournamentPhase.Completed;
            emit TournamentCompleted(_tournamentId, advancing[0]);
            return;
        }
        tournaments[_tournamentId].currentRound = _round + 1;
        tournaments[_tournamentId].roundStartBlock = block.number;
        _createRoundMatches(_tournamentId, _round + 1);
        emit RoundAdvanced(_tournamentId, _round + 1);
    }

    // ==================== PHASE 5: PAYOUT ====================

    function claimPrize(uint256 _tournamentId) external nonReentrant {
        Tournament storage t = tournaments[_tournamentId];
        if (t.phase != TournamentPhase.Completed) revert NotCompleted();
        if (msg.sender != t.winner) revert NotWinner();
        if (t.prizeClaimed) revert PrizeAlreadyClaimed();
        t.prizeClaimed = true;
        uint256 amount = t.prizePool;
        t.prizePool = 0;
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit PrizeClaimed(_tournamentId, msg.sender, amount);
    }

    /**
     * @notice Adminless escape hatch: cancel tournament and enable refunds if it stalls.
     * @dev Condition: Active tournament with no progress for STALL_BLOCKS blocks.
     * Refunds are pull-based via pendingWithdrawals.
     */
    function cancelStalledTournament(uint256 _tournamentId) external nonReentrant {
        Tournament storage t = tournaments[_tournamentId];
        if (t.id == 0) revert TournamentNotFound();
        if (t.phase != TournamentPhase.Active) revert NotActive();
        if (block.number <= t.roundStartBlock + STALL_BLOCKS) revert NotCancelableYet();

        t.phase = TournamentPhase.Canceled;

        address[] storage players = tournamentPlayers[_tournamentId];
        uint256 amt = tournamentConfig[_tournamentId].minEntry;
        for (uint256 i = 0; i < players.length; i++) {
            pendingWithdrawals[players[i]] += amt;
            emit WithdrawalAccrued(players[i], amt);
        }
        t.prizePool = 0;
        emit TournamentCanceled(_tournamentId);
    }

    /**
     * @notice Withdraw any pending refunds (and other pull-based payouts if added later).
     */
    function withdrawPending() external nonReentrant {
        uint256 amt = pendingWithdrawals[msg.sender];
        if (amt == 0) return;
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{ value: amt }("");
        if (!ok) revert TransferFailed();
    }

    // ==================== DRAND HELPERS ====================

    function _readSubstrateStorage(bytes memory key) internal view returns (bytes memory) {
        (bool success, bytes memory result) = STORAGE_PRECOMPILE.staticcall(key);
        return success ? result : new bytes(0);
    }

    function _getLastStoredRound() internal view returns (uint64) {
        (bool ok, bytes memory data) = DRAND_PRECOMPILE.staticcall(abi.encodeWithSignature("getLastStoredRound()"));
        if (ok && data.length >= 32) return abi.decode(data, (uint64));
        bytes memory key = new bytes(32);
        bytes32 k = DRAND_LAST_ROUND_KEY;
        assembly ("memory-safe") { mstore(add(key, 32), k) }
        data = _readSubstrateStorage(key);
        if (data.length < 8) return 0;
        uint64 round = 0;
        for (uint256 i = 0; i < 8; i++) round |= uint64(uint8(data[i])) << uint64(i * 8);
        return round;
    }

    function _getDrandRandomness(uint64 round) internal view returns (bool exists, bytes32 randomness) {
        // Preferred ABI (subtensor PR #2445): getRandomness(uint64) -> bytes32 (zero indicates missing)
        (bool ok, bytes memory data) = DRAND_PRECOMPILE.staticcall(abi.encodeWithSignature("getRandomness(uint64)", round));
        if (ok && data.length >= 32) {
            bytes32 r = abi.decode(data, (bytes32));
            return (r != bytes32(0), r);
        }

        // Backward-compatible ABI (older local mocks / deployments): getPulse(uint64) -> (bool, bytes32)
        (ok, data) = DRAND_PRECOMPILE.staticcall(abi.encodeWithSignature("getPulse(uint64)", round));
        if (ok && data.length >= 64) {
            (bool ex, bytes32 r2) = abi.decode(data, (bool, bytes32));
            return (ex, r2);
        }

        bytes memory key = _buildDrandPulseKey(round);
        bytes memory storageData = _readSubstrateStorage(key);
        if (storageData.length == 0) return (false, bytes32(0));
        if (storageData.length < 41) return (false, bytes32(0));
        uint8 compactLen = uint8(storageData[8]);
        uint256 randomnessLen;
        uint256 randomnessStart;
        if ((compactLen & 0x03) == 0) {
            randomnessLen = compactLen >> 2;
            randomnessStart = 9;
        } else if ((compactLen & 0x03) == 1 && storageData.length >= 10) {
            uint16 val = uint16(compactLen) | (uint16(uint8(storageData[9])) << 8);
            randomnessLen = val >> 2;
            randomnessStart = 10;
        } else return (false, bytes32(0));
        if (randomnessLen != 32) return (false, bytes32(0));
        if (storageData.length < randomnessStart + 32) return (false, bytes32(0));
        bytes32 rand;
        assembly ("memory-safe") { rand := mload(add(add(storageData, 32), randomnessStart)) }
        return (true, rand);
    }

    function _blake2b128(bytes memory data) internal pure returns (bytes16 hash) {
        require(data.length == 8, "blake2b128: need 8 bytes");
        uint64 iv0 = 0x6a09e667f3bcc908;
        uint64 p0 = 0x01010010;
        uint64 h0 = (iv0 & 0xffffffff00000000) | (uint64(uint32(iv0) ^ uint32(p0)));
        uint64[8] memory h = [h0, uint64(0xbb67ae8584caa73b), uint64(0x3c6ef372fe94f82b), uint64(0xa54ff53a5f1d36f1), uint64(0x510e527fade682d1), uint64(0x9b05688c2b3e6c1f), uint64(0x1f83d9abfb41bd6b), uint64(0x5be0cd19137e2179)];
        uint64[16] memory m;
        m[0] = uint64(uint8(data[0])) | (uint64(uint8(data[1])) << 8) | (uint64(uint8(data[2])) << 16) | (uint64(uint8(data[3])) << 24) | (uint64(uint8(data[4])) << 32) | (uint64(uint8(data[5])) << 40) | (uint64(uint8(data[6])) << 48) | (uint64(uint8(data[7])) << 56);
        uint64 t0 = 8; uint64 t1 = 0; uint64 f = 0xffffffffffffffff;
        (h,) = _blake2bCompress(h, m, t0, t1, f);
        bytes memory out16 = new bytes(16);
        for (uint256 i = 0; i < 8; i++) { out16[i] = bytes1(uint8((h[0] >> (i * 8)) & 0xff)); out16[8 + i] = bytes1(uint8((h[1] >> (i * 8)) & 0xff)); }
        assembly ("memory-safe") { hash := mload(add(out16, 32)) }
        return hash;
    }

    function _blake2bCompress(uint64[8] memory h, uint64[16] memory m, uint64 t0, uint64 t1, uint64 f) internal pure returns (uint64[8] memory out, uint64[16] memory) {
        uint64[16] memory v;
        for (uint256 i = 0; i < 8; i++) v[i] = h[i];
        v[8] = 0x6a09e667f3bcc908; v[9] = 0xbb67ae8584caa73b; v[10] = 0x3c6ef372fe94f82b; v[11] = 0xa54ff53a5f1d36f1;
        v[12] = 0x510e527fade682d1 ^ t0; v[13] = 0x9b05688c2b3e6c1f ^ t1; v[14] = 0x1f83d9abfb41bd6b ^ f; v[15] = 0x5be0cd19137e2179;
        for (uint256 r = 0; r < 12; r++) {
            uint256[16] memory s = _blake2bSigma(r);
            _g(v, m, s[0], s[1], 0, 4, 8, 12); _g(v, m, s[2], s[3], 1, 5, 9, 13); _g(v, m, s[4], s[5], 2, 6, 10, 14); _g(v, m, s[6], s[7], 3, 7, 11, 15);
            _g(v, m, s[8], s[9], 0, 5, 10, 15); _g(v, m, s[10], s[11], 1, 6, 11, 12); _g(v, m, s[12], s[13], 2, 7, 8, 13); _g(v, m, s[14], s[15], 3, 4, 9, 14);
        }
        unchecked { for (uint256 i = 0; i < 8; i++) out[i] = h[i] ^ v[i] ^ v[i + 8]; }
        return (out, m);
    }

    function _g(uint64[16] memory v, uint64[16] memory m, uint256 a, uint256 b, uint256 i, uint256 j, uint256 k, uint256 l) private pure {
        unchecked {
            v[i] = v[i] + v[j] + m[a]; v[l] = _rotr64(v[l] ^ v[i], 32); v[k] = v[k] + v[l]; v[j] = _rotr64(v[j] ^ v[k], 24);
            v[i] = v[i] + v[j] + m[b]; v[l] = _rotr64(v[l] ^ v[i], 16); v[k] = v[k] + v[l]; v[j] = _rotr64(v[j] ^ v[k], 63);
        }
    }

    function _rotr64(uint64 x, uint256 n) private pure returns (uint64) {
        return (x >> uint64(n)) | (x << (64 - uint64(n)));
    }

    function _blake2bSigma(uint256 r) private pure returns (uint256[16] memory s) {
        uint8[16][12] memory sigma = [
            [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],[14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],[11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4],[7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8],[9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13],[2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9],[12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11],[13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10],[6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5],[10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0],[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],[14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3]
        ];
        for (uint256 i = 0; i < 16; i++) s[i] = sigma[r][i];
    }

    function _buildDrandPulseKey(uint64 round) internal pure returns (bytes memory) {
        bytes memory roundLE = new bytes(8);
        for (uint256 i = 0; i < 8; i++) { roundLE[i] = bytes1(uint8(round)); round = round >> 8; }
        bytes16 hash = _blake2b128(roundLE);
        bytes memory key = new bytes(56);
        bytes memory prefix = DRAND_PULSES_PREFIX;
        for (uint256 i = 0; i < 32; i++) key[i] = prefix[i];
        for (uint256 i = 0; i < 16; i++) key[32 + i] = hash[i];
        for (uint256 i = 0; i < 8; i++) key[48 + i] = roundLE[i];
        return key;
    }

    receive() external payable { revert DirectETHNotAccepted(); }
}
