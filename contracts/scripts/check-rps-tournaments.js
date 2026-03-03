/**
 * Fetch and print tournament details from an RPS_Tournament contract.
 *
 * Usage:
 *   RPS_CONTRACT_ADDRESS=0x... npx hardhat run scripts/check-rps-tournaments.js [--network <name>]
 *   RPS_CONTRACT_ADDRESS=0x... TOURNAMENT_ID=2 npx hardhat run scripts/check-rps-tournaments.js [--network <name>]
 *
 * If TOURNAMENT_ID is set, only that tournament is shown. Otherwise all tournaments (1 .. nextTournamentId-1) are listed.
 */
const hre = require("hardhat");

const PHASE_NAMES = ["Registration", "Active", "Canceled", "Completed"];
const MAX_PLAYERS = 16;

function phaseName(phaseNum) {
  const n = Number(phaseNum);
  return PHASE_NAMES[n] != null ? PHASE_NAMES[n] : `Unknown(${n})`;
}

/** Fetch dynamic array from contract where getter is (id, index) => element. Stops on revert or after maxLen. */
async function fetchMappingArray(contract, methodName, id, maxLen = MAX_PLAYERS) {
  const out = [];
  for (let i = 0; i < maxLen; i++) {
    try {
      const val = await contract[methodName](id, i);
      if (val === hre.ethers.ZeroAddress) break;
      out.push(val);
    } catch (_) {
      break;
    }
  }
  return out;
}

async function main() {
  const contractAddress = process.env.RPS_CONTRACT_ADDRESS;
  if (!contractAddress) {
    console.error("Usage: RPS_CONTRACT_ADDRESS=0x... [TOURNAMENT_ID=id] npx hardhat run scripts/check-rps-tournaments.js [--network <name>]");
    process.exit(1);
  }

  const singleId = process.env.TOURNAMENT_ID ? parseInt(process.env.TOURNAMENT_ID, 10) : null;
  if (singleId !== null && (isNaN(singleId) || singleId < 1)) {
    console.error("TOURNAMENT_ID must be a positive integer.");
    process.exit(1);
  }

  console.log("\n=== RPS Tournament – Contract state ===\n");
  console.log("Contract:", contractAddress);
  console.log("Network:", hre.network.name);
  console.log("");

  const rps = await hre.ethers.getContractAt("RPS_Tournament", contractAddress);
  let nextId;
  try {
    nextId = await rps.nextTournamentId();
  } catch (e) {
    if (e.info && e.info.method === "nextTournamentId" && (e.code === "BAD_DATA" || e.value === "0x")) {
      console.error("No contract at this address or wrong network (empty response). Ensure RPS_CONTRACT_ADDRESS is deployed on the selected network.");
    }
    throw e;
  }
  const next = Number(nextId);
  if (next <= 1) {
    console.log("No tournaments created yet (nextTournamentId = 1).");
    console.log("");
    process.exit(0);
  }

  const ids = singleId !== null ? [singleId] : Array.from({ length: next - 1 }, (_, i) => i + 1);
  if (singleId !== null && singleId >= next) {
    console.log("Tournament ID", singleId, "does not exist (nextTournamentId =", next, ").");
    console.log("");
    process.exit(1);
  }

  for (const id of ids) {
    if (id >= next) {
      console.log("Tournament", id, "does not exist. Skipping.\n");
      continue;
    }

    const t = await rps.tournaments(id);
    const cfg = await rps.tournamentConfig(id);
    const players = await fetchMappingArray(rps, "tournamentPlayers", id, Number(cfg.maxPlayers) || MAX_PLAYERS);

    console.log("---------- Tournament", id, "----------");
    console.log("  Phase:           ", phaseName(t.phase));
    console.log("  Creator:         ", t.creator);
    const latestBlock = await hre.ethers.provider.getBlockNumber();
    const regEndBlock = Number(t.registrationEndBlock);
    const blocksLeft = Math.max(0, regEndBlock - latestBlock);
    console.log("  Registration end block:", regEndBlock.toString(), "(in ~" + blocksLeft + " blocks; latest=" + latestBlock + ")");
    console.log("  Prize pool:      ", hre.ethers.formatEther(t.prizePool), "TAO");
    console.log("  Current round:   ", t.currentRound.toString());
    console.log("  Round start block:", t.roundStartBlock.toString());
    console.log("  Winner:          ", t.winner === hre.ethers.ZeroAddress ? "(none)" : t.winner);
    console.log("  Prize claimed:   ", t.prizeClaimed);

    console.log("  Config:");
    console.log("    maxPlayers:        ", cfg.maxPlayers);
    console.log("    minEntry:          ", hre.ethers.formatEther(cfg.minEntry), "TAO");
    console.log("    commitBlocks:      ", cfg.commitBlocks.toString());
    console.log("    revealBlocks:      ", cfg.revealBlocks.toString());
    console.log("    maxRPSRoundsPerMatch:", cfg.maxRPSRoundsPerMatch.toString());

    console.log("  Registered players:", players.length, "/", cfg.maxPlayers);
    if (players.length) {
      players.forEach((a, i) => console.log("    [" + i + "]", a));
    }

    const round = Number(t.currentRound);
    const phase = Number(t.phase);
    if (phase === 1 || phase === 3) {
      const advancing = await fetchMappingArray(rps, "tournamentAdvancingPlayers", id);
      console.log("  Advancing players:", advancing.length);
      if (advancing.length) advancing.forEach((a, i) => console.log("    [" + i + "]", a));

      const matchCount = await rps.tournamentMatchCount(id, t.currentRound);
      const n = Number(matchCount);
      if (n > 0) {
        console.log("  Round", round, "matches:", n);
        for (let m = 0; m < n; m++) {
          const match = await rps.matches(id, t.currentRound, m);
          const bye = match.playerB === hre.ethers.ZeroAddress;
          console.log("    Match", m, ":", match.playerA, bye ? "(bye)" : "vs", bye ? "" : match.playerB, "| winner:", match.winner === hre.ethers.ZeroAddress ? "-" : match.winner);
        }
      }
    }

    console.log("");
  }

  console.log("Done.");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
