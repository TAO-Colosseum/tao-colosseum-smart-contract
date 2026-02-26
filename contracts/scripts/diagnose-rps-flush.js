/**
 * Diagnose why RPS flushFeesToSubnetAndBurn() reverts.
 *
 * Usage:
 *   RPS_CONTRACT_ADDRESS=0x... npx hardhat run scripts/diagnose-rps-flush.js --network bittensor
 * Optional:
 *   TEST_STAKING_PRECOMPILE=1 TEST_TAO=0.000001 ...  (tries direct addStake/burnAlpha from signer)
 */
const hre = require("hardhat");

const STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805";
const NETUID_SN38 = 38n;

const STAKING_ABI = [
  "function getTotalAlphaStaked(bytes32 hotkey, uint256 netuid) view returns (uint256)",
  "function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) payable",
  "function burnAlpha(bytes32 hotkey, uint256 amount, uint256 netuid) payable",
];

function fmtErr(e) {
  return e?.reason || e?.shortMessage || e?.message || String(e);
}

async function main() {
  const address = process.env.RPS_CONTRACT_ADDRESS;
  if (!address) {
    console.error("Set RPS_CONTRACT_ADDRESS=0x...");
    process.exit(1);
  }

  const [signer] = await hre.ethers.getSigners();
  const rps = await hre.ethers.getContractAt("RPS_Tournament", address);
  const staking = new hre.ethers.Contract(STAKING_PRECOMPILE, STAKING_ABI, signer);

  console.log("Network:", hre.network.name);
  console.log("Signer:", signer.address);
  console.log("RPS:", address);
  console.log("");

  const hotkey = await rps.sn38OwnerHotkey();
  const fees = await rps.accumulatedFees();
  const rpsBal = await hre.ethers.provider.getBalance(address);
  const signerBal = await hre.ethers.provider.getBalance(signer.address);

  console.log("sn38OwnerHotkey (bytes32):", hotkey);
  console.log("accumulatedFees:", hre.ethers.formatEther(fees), "TAO");
  console.log("RPS balance:", hre.ethers.formatEther(rpsBal), "TAO");
  console.log("Signer balance:", hre.ethers.formatEther(signerBal), "TAO");
  console.log("");

  try {
    const alpha = await staking.getTotalAlphaStaked(hotkey, NETUID_SN38);
    console.log("getTotalAlphaStaked(hotkey,38):", alpha.toString());
  } catch (e) {
    console.log("getTotalAlphaStaked failed:", fmtErr(e));
  }

  console.log("");
  try {
    const gas = await rps.flushFeesToSubnetAndBurn.estimateGas();
    console.log("flushFeesToSubnetAndBurn estimateGas:", gas.toString());
  } catch (e) {
    console.log("flushFeesToSubnetAndBurn estimateGas failed:", fmtErr(e));
  }

  if (process.env.TEST_STAKING_PRECOMPILE === "1") {
    const testTao = process.env.TEST_TAO || "0.000001";
    const amountRao = hre.ethers.parseUnits(testTao, 9);
    console.log("\n--- Direct precompile probe (from signer) ---");
    console.log("TEST_TAO:", testTao);
    console.log("TEST_RAO:", amountRao.toString());

    try {
      const gas = await staking.addStake.estimateGas(hotkey, amountRao, NETUID_SN38);
      console.log("addStake estimateGas (direct):", gas.toString());
    } catch (e) {
      console.log("addStake estimateGas failed (direct):", fmtErr(e));
    }

    try {
      const tx = await staking.addStake(hotkey, amountRao, NETUID_SN38);
      const rcpt = await tx.wait();
      console.log("addStake tx hash:", tx.hash, "status:", rcpt.status);
    } catch (e) {
      console.log("addStake tx failed (direct):", fmtErr(e));
    }

    try {
      const alphaAfter = await staking.getTotalAlphaStaked(hotkey, NETUID_SN38);
      console.log("getTotalAlphaStaked after direct addStake:", alphaAfter.toString());
      if (alphaAfter > 0n) {
        try {
          const gas = await staking.burnAlpha.estimateGas(hotkey, 1n, NETUID_SN38);
          console.log("burnAlpha(1) estimateGas (direct):", gas.toString());
        } catch (e) {
          console.log("burnAlpha estimateGas failed (direct):", fmtErr(e));
        }
      }
    } catch (e) {
      console.log("post-addStake alpha query failed:", fmtErr(e));
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
