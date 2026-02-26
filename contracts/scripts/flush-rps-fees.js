/**
 * Call flushFeesToSubnetAndBurn() on RPS_Tournament.
 * Usage: RPS_CONTRACT_ADDRESS=0x... npx hardhat run scripts/flush-rps-fees.js [--network bittensorTestnet]
 */
const hre = require("hardhat");

async function main() {
  const address = process.env.RPS_CONTRACT_ADDRESS;
  if (!address) {
    console.error("Set RPS_CONTRACT_ADDRESS=0x...");
    process.exit(1);
  }

  const rps = await hre.ethers.getContractAt("RPS_Tournament", address);
  const fees = await rps.accumulatedFees();
  const weiPerRao = await rps.WEI_PER_RAO();

  if (fees === 0n) {
    console.log("No accumulated fees. Exiting.");
    return;
  }

  const balance = await hre.ethers.provider.getBalance(address);
  const flushWei = (fees / weiPerRao) * weiPerRao;
  console.log("Accumulated fees:", hre.ethers.formatEther(fees), "TAO");
  console.log("Contract balance:", hre.ethers.formatEther(balance), "TAO");
  console.log("Flushable now:", hre.ethers.formatEther(flushWei), "TAO");
  if (flushWei === 0n) {
    console.log("Only sub-RAO dust is pending; nothing flushable yet.");
    return;
  }
  if (balance < flushWei) {
    console.error("Contract balance < flushable fee amount.");
    process.exit(1);
  }
  console.log("Calling flushFeesToSubnetAndBurn()...");

  try {
    const tx = await rps.flushFeesToSubnetAndBurn();
    await tx.wait();
    console.log("Tx hash:", tx.hash);
    console.log("Done.");
  } catch (e) {
    const reason = e.reason || e.message;
    const data = e.data || e.error?.data || e.transaction?.data;
    console.error("Revert reason:", reason);
    if (data && typeof data === "string" && data.length > 10) {
      console.error("Revert data (hex):", data.slice(0, 74));
    }
    throw e;
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
