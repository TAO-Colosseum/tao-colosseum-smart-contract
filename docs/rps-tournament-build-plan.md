# RPS Tournament Contract – Build Plan (Drand Auto-Reveal)

This document is the step-by-step plan for building the RPS Tournament smart contract on Bittensor EVM with **drand-based auto-reveal** (timelock encryption, no second tx from the player).

---

## 1. Dependency: TLE Decrypt On-Chain

**CRv3 on Substrate** uses timelock encryption (TLE): the validator encrypts the payload with a **future drand round’s public key**; when that round is on-chain, the runtime decrypts using the drand pulse’s BLS signature. No second transaction from the user.

**On Bittensor EVM we need one of:**

- **Option A (recommended):** A **TLE precompile** (e.g. at a fixed address) that exposes something like:
  - `decryptTimelock(bytes calldata ciphertext, uint64 round) returns (bool success, bytes memory plaintext)`
  - It reads the pulse for `round` from drand pallet storage and runs TLE decrypt (BLS + AES-GCM) internally, returns the RPS payload (e.g. `abi.encode(choice)`).
- **Option B:** Expose the **full pulse** (including BLS signature) to EVM (e.g. extended drand precompile: `getPulseFull(uint64) returns (round, randomness, signature)`), then implement or link a Solidity-friendly TLE decrypt (BLS + AES-GCM). Gas and complexity are high.

**For the build plan we assume Option A.** The contract will call a precompile interface; tests can use a mock. If the precompile does not exist yet, document the required interface and implement a mock for local tests.

---

## 2. High-Level Flow

1. **Create** tournament (config: maxPlayers ∈ {4, 8, 16}, maxRegTime, minEntry, commitBlocks, revealBlocks).
2. **Register** (pay minEntry before deadline).
3. **Start** (anyone): when slots full **or** time’s up and players ≥ 2; else **Cancel** (anyone) when time’s up and &lt; 2 (full refund).
4. **Bracket**: drand shuffle players, drand bye if odd; create round 0 matches.
5. **Per match – Commit**: each player submits **TLE ciphertext** + **revealRound** (future drand round). Commit window = N blocks.
6. **Per match – Reveal (auto)**: anyone calls `tryRevealMatch(tournamentId, matchId)`. Contract uses precompile to decrypt each player’s ciphertext with pulse(revealRound). If one didn’t commit → other wins; both didn’t commit → drand picks one to advance. Compare RPS; tie → replay up to max rounds then drand; set winner.
7. **Round advancement**: when all matches in the round have a winner, build next round (drand pairing + bye), start commit phase.
8. **Final**: one winner; **winner takes all**. Single `claimPrize(tournamentId)` (no re-entrancy from split).

---

## 3. Build Steps (Ordered)

### Phase 1: Foundation & Config

| Step | Task | Details |
|------|------|--------|
| **1.1** | Create contract file and skeleton | New file e.g. `contracts/contracts/RPS_Tournament.sol`. SPDX, pragma, contract name. |
| **1.2** | Drand + precompile constants | Reuse TAO_Colosseum pattern: storage precompile `0x0807`, drand precompile `0x080D`, drand storage keys. Add **TLE precompile address** (constant; can be zero until deployed). |
| **1.3** | TLE precompile interface | Define interface e.g. `IDrandTimelock { function decryptTimelock(bytes calldata ciphertext, uint64 round) external view returns (bool success, bytes memory plaintext); }`. Use in contract; mock in tests. |
| **1.4** | Enums and config struct | `TournamentPhase`: Registration, Active, Canceled, Completed. `RPSChoice`: Rock, Paper, Scissors. `TournamentConfig`: maxPlayers (4/8/16), maxRegTime (timestamp), minEntry (wei), commitBlocks, revealBlocks, maxRPSRoundsPerMatch. |
| **1.5** | Tournament and match state structs | `Tournament`: id, config, phase, creator, registrationEnd, players[], prizePool, currentRound, roundStartBlock. `Match`: tournamentId, round, matchIndex, playerA, playerB, bye (address(0) if none), commitEndBlock, revealRound (for TLE), winner (address(0) until resolved). Commit storage: per (tournamentId, matchId, player) → (ciphertext, revealRound). |

### Phase 2: Tournament Lifecycle

| Step | Task | Details |
|------|------|--------|
| **2.1** | `createTournament` | Set config (validate maxPlayers ∈ {4,8,16}, minEntry ≥ 0.5 TAO, commitBlocks/revealBlocks &gt; 0). Push new tournament; emit event. |
| **2.2** | `register(tournamentId)` | Require phase == Registration, block.timestamp &lt; registrationEnd, not already registered, players.length &lt; maxPlayers, msg.value ≥ minEntry. Push msg.sender to players, add msg.value to prizePool. |
| **2.3** | `startTournament(tournamentId)` | Callable by anyone. Require phase == Registration and (players.length == maxPlayers **or** (block.timestamp >= registrationEnd **and** players.length >= 2)). Set phase = Active, set registrationEnd, init bracket (see 3.1). |
| **2.4** | `cancelTournament(tournamentId)` | Callable by anyone. Require phase == Registration, block.timestamp >= registrationEnd, players.length &lt; 2. Set phase = Canceled; refund each player their entry (transfer). |
| **2.5** | Bracket initialization (internal) | On start: get drand randomness (e.g. last stored round + 1). Shuffle `players` with drand (Fisher–Yates). If odd N, drand pick bye index; build round 0 matches (pairs + one bye). Set roundStartBlock = block.number, commitEndBlock = block.number + commitBlocks. Store revealRound = f(lastStoredRound, commitBlocks) so pulse is available after commit window. |

### Phase 3: Commit (TLE)

| Step | Task | Details |
|------|------|--------|
| **3.1** | `commitMove(tournamentId, matchId, ciphertext, revealRound)` | Require tournament Active, msg.sender is playerA or playerB of match, block.number ≤ commitEndBlock, revealRound &gt; current drand round (so pulse not yet known). Store (ciphertext, revealRound) for (tournamentId, matchId, msg.sender). Emit event. |
| **3.2** | Payload format | Agree with client: plaintext before TLE = e.g. `abi.encode(choice, salt)` or a small struct (RPSChoice, bytes32 salt). Contract will decode after precompile returns plaintext. |

### Phase 4: Auto-Reveal and Match Resolution

| Step | Task | Details |
|------|------|--------|
| **4.1** | `tryRevealMatch(tournamentId, matchId)` | Callable by anyone. Require block.number &gt; commitEndBlock. For each player: if commit stored, call TLE precompile `decryptTimelock(ciphertext, revealRound)`; if success, decode choice. If one committed and one didn’t → other wins. If both didn’t commit → use drand to pick one to advance. If both committed: compare RPS (standard rules); if tie and subRound &lt; maxRPSRoundsPerMatch, allow “replay” (next subRound); else if tie at max, use drand to pick winner. Set match.winner, emit event. |
| **4.2** | Forfeit and both-no-show | One no-commit → opponent wins. Both no-commit → drand (e.g. randomness % 2) to choose advancing player. Same logic if both committed but decrypt fails for one or both (treat as no-commit). |
| **4.3** | Round advancement | After each match resolution, check if all matches in current round have a winner. If yes: if only one winner left → tournament complete, set phase = Completed, winner can claim. Else build next round: list of advancing players, drand shuffle, drand bye if odd, create next round matches with new commitEndBlock and revealRound. |

### Phase 5: Payout and Safety

| Step | Task | Details |
|------|------|--------|
| **5.1** | `claimPrize(tournamentId)` | Require phase == Completed, msg.sender == tournament winner. Transfer full prizePool to winner; set a flag or zero out prizePool so single claim. Use checks-effects-interactions and reentrancy guard. |
| **5.2** | Reentrancy guard | Apply to register, cancel (refunds), claimPrize. |
| **5.3** | Drand helpers | Internal `_getLastStoredRound()`, `_getDrandRandomness(round)` (reuse TAO_Colosseum logic). Use for: shuffle, bye, tiebreak, both-no-show. |

### Phase 6: Testing and Docs

| Step | Task | Details |
|------|------|--------|
| **6.1** | Mock TLE precompile | Forge/Hardhat: deploy a mock that stores (ciphertext → plaintext) and returns plaintext when `decryptTimelock(ciphertext, round)` is called (ignore round or use fixed round). |
| **6.2** | Unit tests | Create tournament, register 4/8/16, start; cancel path (&lt;2 at deadline); commit/reveal one match (with mock); forfeit (one commit); both no-show (drand); tie then drand; full bracket to one winner; claimPrize. |
| **6.3** | Update docs | In `docs/games.md` update RPS section: commit = TLE ciphertext + revealRound; reveal = anyone calls tryRevealMatch, chain decrypts with drand (auto-reveal). Note dependency on TLE precompile. |

---

## 4. Summary Checklist

- [x] **1** Contract skeleton + drand + TLE precompile interface and constants  
- [x] **2** Tournament config and state (tournament, match, commits)  
- [x] **3** createTournament, register, startTournament, cancelTournament  
- [x] **4** Bracket init with drand (shuffle, bye)  
- [x] **5** commitMove (TLE ciphertext + revealRound)  
- [x] **6** tryRevealMatch (precompile decrypt, resolve RPS, forfeits, tie/drand)  
- [x] **7** Round advancement when all matches in round have winner  
- [x] **8** claimPrize (winner takes all), reentrancy guard  
- [x] **9** Mock precompile + tests  
- [ ] **10** Docs update (games.md)  

---

## 5. TLE Precompile Requirement (for Bittensor EVM)

If the precompile does not exist yet, the following interface should be implemented and exposed to EVM (e.g. at a fixed address):

- **Input**: `ciphertext` (bytes; TLE ciphertext produced by client with drand round R), `round` (uint64).
- **Behavior**: Read drand pulse for `round` from pallet storage; run TLE decrypt (same as Substrate CRv3: BLS + AES-GCM) with the pulse’s signature; return plaintext.
- **Output**: `(bool success, bytes plaintext)`. On failure (missing pulse, decrypt error), return (false, "").

Client flow (off-chain): get current drand round, pick revealRound = current + K (so pulse is available after commit window); encrypt (choice, salt) with TLE for that round; submit (ciphertext, revealRound) in commitMove.

---

*Plan version: 1.0. Next: implement Phase 1 in code.*
