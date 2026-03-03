### Underdog (Minority Wins)

```
Mechanics:
- Players bet on Red or Blue
- Minority side wins, splits entire pool
- drand randomness for anti-sniping

Entry: Min 0.001 TAO
Duration: ~20 minutes (100 blocks)
Fee: 1.5%
```

---

### Game 2: RPS Tournament

```
┌─────────────────────────────────────────────────┐
│                 RPS TOURNAMENT                  │
├─────────────────────────────────────────────────┤
│                                                 │
│  Format: Single-elimination bracket            │
│  Entry: Min 0.5 TAO; sizes: 4, 8, or 16        │
│  Prize: Winner takes ALL entry stakes          │
│                                                 │
│  Round Flow (drand auto-reveal):                │
│  ┌──────────┐    ┌──────────┐                   │
│  │ COMMIT   │ →  │ REVEAL   │  (anyone calls   │
│  │ (TLE +   │    │ (chain   │   tryRevealMatch;│
│  │  round)  │    │ decrypts)│   no 2nd tx)     │
│  └──────────┘    └──────────┘                   │
│                                                 │
│  Example 8-player tournament:                   │
│                                                 │
│     Round 1        Round 2        Final        │
│    ┌───┐                                       │
│  A─┤   ├─┐                                     │
│    └───┘ │  ┌───┐                              │
│          ├──┤   ├─┐                            │
│    ┌───┐ │  └───┘ │                            │
│  B─┤   ├─┘        │  ┌───┐                     │
│    └───┘          ├──┤   ├── WINNER            │
│    ┌───┐          │  └───┘   (takes 8 TAO)     │
│  C─┤   ├─┐        │                            │
│    └───┘ │  ┌───┐ │                            │
│          ├──┤   ├─┘                            │
│    ┌───┐ │  └───┘                              │
│  D─┤   ├─┘                                     │
│    └───┘                                       │
│                                                 │
│  Sybil Resistance:                              │
│  - Random bracket seeding                       │
│  - Your bots may face each other (waste money)  │
│  - Can't choose opponent                        │
│                                                 │
│  Edge Cases:                                    │
│  - Tie: Replay same matchup                     │
│  - No reveal: Forfeit (opponent wins)           │
│  - Timeout: Auto-forfeit after deadline         │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

### Game 3: Threshold Catastrophe (Reverse Chicken)

```
┌─────────────────────────────────────────────────┐
│           THRESHOLD CATASTROPHE                 │
├─────────────────────────────────────────────────┤
│                                                 │
│  Concept: Don't be the one who breaks it!       │
│                                                 │
│  Threshold: 100 TAO (example)                   │
│  Prior Prize Pool: 50 TAO (from previous round) │
│                                                 │
│  Phase 1 - COMMIT (hidden bets):                │
│  ┌────────────────────────────────────────┐     │
│  │ Player A commits: hash(15 TAO + salt)  │     │
│  │ Player B commits: hash(20 TAO + salt)  │     │
│  │ Player C commits: hash(25 TAO + salt)  │     │
│  │ Player D commits: hash(30 TAO + salt)  │     │
│  │ Player E commits: hash(18 TAO + salt)  │     │
│  │                                        │     │
│  │ Nobody knows others' amounts!          │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  Phase 2 - REVEAL (in order of commit time):    │
│  ┌────────────────────────────────────────┐     │
│  │ A reveals 15 → Running total: 15  ✓    │     │
│  │ B reveals 20 → Running total: 35  ✓    │     │
│  │ C reveals 25 → Running total: 60  ✓    │     │
│  │ D reveals 30 → Running total: 90  ✓    │     │
│  │ E reveals 18 → Running total: 108 ✗    │     │
│  │                    EXCEEDS THRESHOLD!  │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  RESULT: Threshold broken at Player E           │
│                                                 │
│  → Player D WINS (last before threshold)        │
│  → D gets: All bets (108) + Prior pool (50)     │
│            = 158 TAO                            │
│                                                 │
│  ─────────────────────────────────────────────  │
│                                                 │
│  ALTERNATIVE SCENARIO:                          │
│  If total never exceeds threshold:              │
│  ┌────────────────────────────────────────┐     │
│  │ Total bets: 88 TAO (under 100)         │     │
│  │                                        │     │
│  │ ALL players lose!                      │     │
│  │ 88 TAO → Next round's prize pool       │     │
│  │                                        │     │
│  │ (Encourages aggressive betting)        │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  Sybil Resistance:                              │
│  - More bots = higher total = more likely to    │
│    break threshold before YOUR bot is "last"    │
│  - Can't coordinate timing (commit order fixed) │
│  - Hidden amounts prevent calculation           │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

### Game 4: Last Stander (Extremes Lose)

```
┌─────────────────────────────────────────────────┐
│              LAST STANDER                       │
├─────────────────────────────────────────────────┤
│                                                 │
│  Concept: Don't be the highest OR lowest!       │
│           Extremes are eliminated.              │
│                                                 │
│  Entry: Commit any amount (min 0.1 TAO)         │
│                                                 │
│  Phase 1 - COMMIT:                              │
│  Players secretly commit their bid amounts      │
│                                                 │
│  Phase 2 - REVEAL:                              │
│  ┌────────────────────────────────────────┐     │
│  │ Revealed bids (sorted):                │     │
│  │                                        │     │
│  │   Player F: 0.5 TAO  ← LOWEST (LOSES)  │     │
│  │   Player A: 1.2 TAO  ✓ survivor        │     │
│  │   Player C: 2.0 TAO  ✓ survivor        │     │
│  │   Player B: 2.5 TAO  ✓ survivor        │     │
│  │   Player E: 3.0 TAO  ✓ survivor        │     │
│  │   Player D: 5.0 TAO  ← HIGHEST (LOSES) │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  RESULT:                                        │
│  - Player D (highest) loses 5.0 TAO             │
│  - Player F (lowest) loses 0.5 TAO              │
│  - Total loser pool: 5.5 TAO                    │
│                                                 │
│  - Survivors: A, B, C, E                        │
│  - Each survivor gets: 5.5 / 4 = 1.375 TAO      │
│  - Plus their original stake returned           │
│                                                 │
│  Strategic Depth:                               │
│  ┌────────────────────────────────────────┐     │
│  │ - Bid too high → You're the max, lose  │     │
│  │ - Bid too low → You're the min, lose   │     │
│  │ - Bid "average" → Safe but small gain  │     │
│  │                                        │     │
│  │ The game: Predict the distribution!    │     │
│  │ Where is the "safe middle"?            │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  Sybil Resistance:                              │
│  - Multiple bots = multiple chances to be       │
│    the extreme (highest or lowest)              │
│  - Can't cover "all" the middle safely          │
│  - More bots = more entry fees at risk          │
│                                                 │
│  Variation: Top N and Bottom N lose             │
│  (for larger player pools)                      │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

### Game 5: Anti-Coordination Slots

```
┌─────────────────────────────────────────────────┐
│           ANTI-COORDINATION SLOTS               │
├─────────────────────────────────────────────────┤
│                                                 │
│  Concept: Pick a slot nobody else picks!        │
│                                                 │
│  Setup: 24 slots (like hours in a day)          │
│  Entry: Min 0.1 TAO per slot                    │
│                                                 │
│  Players commit to slots with their stakes:     │
│  ┌────────────────────────────────────────┐     │
│  │ Slot 0:  Player A (2 TAO)              │     │
│  │          Player B (1 TAO)  ← COLLISION │     │
│  │                                        │     │
│  │ Slot 1:  Player C (3 TAO)  ← UNIQUE!   │     │
│  │                                        │     │
│  │ Slot 2:  (empty)                       │     │
│  │                                        │     │
│  │ Slot 3:  Player D (1 TAO)              │     │
│  │          Player E (2 TAO)              │     │
│  │          Player F (1 TAO)  ← COLLISION │     │
│  │                                        │     │
│  │ Slot 4:  Player G (4 TAO)  ← UNIQUE!   │     │
│  │                                        │     │
│  │ ...                                    │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  RESOLUTION:                                    │
│  ┌────────────────────────────────────────┐     │
│  │ Collision slots (0, 3): ALL LOSE       │     │
│  │   A loses 2, B loses 1, D loses 1,     │     │
│  │   E loses 2, F loses 1 = 7 TAO lost    │     │
│  │                                        │     │
│  │ Unique slots (1, 4): WINNERS           │     │
│  │   C and G split the 7 TAO losers pool  │     │
│  │                                        │     │
│  │ Winner share by stake weight:          │     │
│  │   C: 3/(3+4) × 7 = 3 TAO               │     │
│  │   G: 4/(3+4) × 7 = 4 TAO               │     │
│  │                                        │     │
│  │ Plus original stakes returned          │     │
│  └────────────────────────────────────────┘     │
│                                                 │
│  Strategic Depth:                               │
│  - Popular slots = high collision risk          │
│  - Obscure slots = might be unique              │
│  - Higher stake = higher reward IF unique       │
│  - But higher stake on collision = bigger loss  │
│                                                 │
│  Sybil Resistance:                              │
│  - Multiple bots on SAME slot = self-collision  │
│  - Spread across slots = spread thin            │
│  - Can't guarantee uniqueness with more bots    │
│                                                 │
└─────────────────────────────────────────────────┘
```

---

## Phase 3: AI Integration - Werewolf Protocol

```
┌─────────────────────────────────────────────────────────────────────┐
│                    WEREWOLF AI PROTOCOL                             │
│             "Where Humans Bet on AI Reasoning"                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  THE VISION:                                                        │
│  AI agents play Werewolf. Humans observe and bet on the outcome.   │
│  Tests AI reasoning + human prediction skills.                      │
│                                                                     │
│  ═══════════════════════════════════════════════════════════════   │
│                                                                     │
│  GAME SETUP:                                                        │
│  ┌───────────────────────────────────────────────────────────┐     │
│  │                                                           │     │
│  │  8 AI Agents (Reasoning Models from Bittensor subnets)   │     │
│  │                                                           │     │
│  │  🤖 Agent 1    🤖 Agent 2    🤖 Agent 3    🤖 Agent 4    │     │
│  │  🤖 Agent 5    🤖 Agent 6    🤖 Agent 7    🤖 Agent 8    │     │
│  │                                                           │     │
│  │  Roles (secret, assigned by contract via drand):          │     │
│  │  - 2 Werewolves 🐺 (know each other)                      │     │
│  │  - 6 Villagers 👤 (don't know roles)                      │     │
│  │                                                           │     │
│  └───────────────────────────────────────────────────────────┘     │
│                                                                     │
│  ═══════════════════════════════════════════════════════════════   │
│                                                                     │
│  GAME FLOW:                                                         │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ NIGHT PHASE (Off-chain, AI-only)                            │   │
│  │                                                             │   │
│  │ 🐺 Werewolf agents secretly coordinate                      │   │
│  │ 🐺 They choose a victim to eliminate                        │   │
│  │                                                             │   │
│  │ Contract records: "Agent X was eliminated"                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                           ↓                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ MORNING PHASE (On-chain, public)                            │   │
│  │                                                             │   │
│  │ All surviving AI agents submit their ANALYSIS:              │   │
│  │                                                             │   │
│  │ Agent 1: "I suspect Agent 5 because their reasoning         │   │
│  │          about Agent 3's death was inconsistent..."         │   │
│  │                                                             │   │
│  │ Agent 2: "Agent 7's voting pattern suggests they knew       │   │
│  │          who would die. Likely werewolf."                   │   │
│  │                                                             │   │
│  │ Agent 5: "I'm being framed. Notice how Agent 1 is           │   │
│  │          deflecting attention from Agent 4..."              │   │
│  │                                                             │   │
│  │ [All analyses recorded on-chain for transparency]           │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                           ↓                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ BETTING PHASE (Humans participate!)                         │   │
│  │                                                             │   │
│  │ Humans read the AI analyses and place bets:                 │   │
│  │                                                             │   │
│  │ "Who do you think is a Werewolf?"                           │   │
│  │                                                             │   │
│  │   Agent 1: [|||||||     ] 2.5 TAO pool                      │   │
│  │   Agent 2: [||          ] 0.8 TAO pool                      │   │
│  │   Agent 3: [ELIMINATED]                                     │   │
│  │   Agent 4: [||||||||||| ] 4.2 TAO pool  ← Popular suspect   │   │
│  │   Agent 5: [||||||      ] 2.1 TAO pool                      │   │
│  │   Agent 6: [|           ] 0.3 TAO pool                      │   │
│  │   Agent 7: [||||||||    ] 3.1 TAO pool                      │   │
│  │   Agent 8: [|||         ] 1.2 TAO pool                      │   │
│  │                                                             │   │
│  │ Betting uses UNDERDOG MECHANICS:                            │   │
│  │ - If you correctly identify a werewolf                      │   │
│  │ - AND you're in the minority of correct guessers            │   │
│  │ - You get the biggest payout!                               │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                           ↓                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ VOTING PHASE (AI agents vote)                               │   │
│  │                                                             │   │
│  │ Agents vote to eliminate one suspect:                       │   │
│  │                                                             │   │
│  │ Agent 1 votes: Agent 5                                      │   │
│  │ Agent 2 votes: Agent 4                                      │   │
│  │ Agent 4 votes: Agent 5                                      │   │
│  │ Agent 5 votes: Agent 4                                      │   │
│  │ Agent 6 votes: Agent 4                                      │   │
│  │ Agent 7 votes: Agent 5                                      │   │
│  │ Agent 8 votes: Agent 4                                      │   │
│  │                                                             │   │
│  │ Result: Agent 4 eliminated (4 votes vs 3)                   │   │
│  │ Reveal: Agent 4 was... VILLAGER! 👤                         │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                           ↓                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ BETTING RESOLUTION                                          │   │
│  │                                                             │   │
│  │ People who bet on Agent 4: WRONG (not a werewolf)           │   │
│  │ → They lose their bets this round                           │   │
│  │                                                             │   │
│  │ Correct bets accumulate until game ends                     │   │
│  │ Final payout when werewolves revealed                       │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                           ↓                                         │
│                    [NEXT NIGHT]                                     │
│                    [REPEAT UNTIL END]                               │
│                           ↓                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ GAME END CONDITIONS:                                        │   │
│  │                                                             │   │
│  │ VILLAGERS WIN: Both werewolves eliminated                   │   │
│  │ WEREWOLVES WIN: Werewolves = Villagers in count             │   │
│  │                                                             │   │
│  │ FINAL PAYOUT:                                               │   │
│  │ - Players who correctly identified BOTH werewolves          │   │
│  │   at any point share the prize pool                         │   │
│  │ - Earlier correct guesses = bonus multiplier                │   │
│  │                                                             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ═══════════════════════════════════════════════════════════════   │
│                                                                     │
│  WHY THIS IS PERFECT FOR BITTENSOR:                                 │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────┐     │
│  │                                                           │     │
│  │ 1. AI SUBNET INTEGRATION                                  │     │
│  │    - Each agent can be from different Bittensor subnets   │     │
│  │    - Tests which AI models reason best under deception    │     │
│  │    - Creates DEMAND for reasoning model subnets           │     │
│  │                                                           │     │
│  │ 2. HUMAN-AI INTERACTION                                   │     │
│  │    - Humans observe AI reasoning                          │     │
│  │    - Humans bet on AI behavior                            │     │
│  │    - Creates engaging spectator experience                │     │
│  │                                                           │     │
│  │ 3. SYBIL RESISTANT (Betting Layer)                        │     │
│  │    - Uses underdog mechanics for bets                     │     │
│  │    - Can't profit by betting on all agents                │     │
│  │    - Rewards contrarian correct predictions               │     │
│  │                                                           │     │
│  │ 4. AI BENCHMARK                                           │     │
│  │    - Which AI models are best at:                         │     │
│  │      • Deception (as werewolf)                            │     │
│  │      • Detection (as villager)                            │     │
│  │      • Persuasion (in voting)                             │     │
│  │    - Real stakes = real performance incentive             │     │
│  │                                                           │     │
│  │ 5. CONTENT GENERATION                                     │     │
│  │    - AI debates are entertaining to watch                 │     │
│  │    - Creates organic content for Bittensor                │     │
│  │    - "Watch AI agents try to deceive each other"          │     │
│  │                                                           │     │
│  └───────────────────────────────────────────────────────────┘     │
│                                                                     │
│  TECHNICAL REQUIREMENTS:                                            │
│  - AI agent interface (submit analyses, votes)                      │
│  - On-chain game state management                                   │
│  - Off-chain coordinator for night phase                            │
│  - Integration with AI subnets for agent responses                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```
