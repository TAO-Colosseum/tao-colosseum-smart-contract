/**
 * Manual test script for the sn38 fee path:
 *   1) read alpha before
 *   2) addStake(hotkey, amountRao, netuid)
 *   3) read alpha after
 *   4) burnAlpha(hotkey, alphaReceived, netuid)
 *
 * Usage:
 *   SN38_OWNER_HOTKEY=0x... AMOUNT_TAO=0.2 npx hardhat run scripts/manual-stake-burn-sn38.js --network bittensor
 *
 * Optional:
 *   NETUID=38
 */
const hre = require("hardhat");

const STAKING_PRECOMPILE = "0x0000000000000000000000000000000000000805";

const STAKING_ABI = [
  "function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) payable",
  "function getTotalAlphaStaked(bytes32 hotkey, uint256 netuid) view returns (uint256)",
  "function burnAlpha(bytes32 hotkey, uint256 amount, uint256 netuid) payable",
];

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function fmtErr(e) {
  return e?.reason || e?.shortMessage || e?.message || String(e);
}

async function main() {
  const hotkey = process.env.SN38_OWNER_HOTKEY;
  if (!hotkey || !/^0x[0-9a-fA-F]{64}$/.test(hotkey)) {
    fail("SN38_OWNER_HOTKEY must be 32-byte hex (0x + 64 hex chars).");
  }

  const amountTao = process.env.AMOUNT_TAO;
  if (!amountTao) fail("Set AMOUNT_TAO, e.g. AMOUNT_TAO=0.2");
  const amountRao = hre.ethers.parseUnits(amountTao, 9); // staking precompile expects RAO
  if (amountRao <= 0n) fail("AMOUNT_TAO must be > 0");

  const netuid = BigInt(process.env.NETUID || "38");

  const [signer] = await hre.ethers.getSigners();
  const staking = new hre.ethers.Contract(STAKING_PRECOMPILE, STAKING_ABI, signer);

  console.log("Network:", hre.network.name);
  console.log("Signer:", signer.address);
  console.log("Hotkey:", hotkey);
  console.log("Netuid:", netuid.toString());
  console.log("Amount (TAO):", amountTao);
  console.log("Amount (RAO):", amountRao.toString());
  console.log("");

  const signerBal = await hre.ethers.provider.getBalance(signer.address);
  console.log("Signer balance:", hre.ethers.formatEther(signerBal), "TAO");
  // if (signerBal < amountRao * 1000000000n) {
  //   fail("Signer balance is lower than AMOUNT_TAO.");
  // }

  let alphaBefore;
  try {
    alphaBefore = await staking.getTotalAlphaStaked(hotkey, netuid);
    console.log("alphaBefore:", alphaBefore.toString());
  } catch (e) {
    fail("getTotalAlphaStaked failed: " + fmtErr(e));
  }

  try {
    const gas = await staking.addStake.estimateGas(hotkey, amountRao, netuid);
    console.log("addStake estimateGas:", gas.toString());
  } catch (e) {
    fail("addStake estimateGas failed: " + fmtErr(e));
  }

  console.log("Calling addStake...");
  try {
    const tx = await staking.addStake(hotkey, amountRao, netuid);
    const rcpt = await tx.wait();
    console.log("addStake tx:", tx.hash, "status:", rcpt.status);
  } catch (e) {
    fail("addStake failed: " + fmtErr(e));
  }

  let alphaAfter;
  try {
    alphaAfter = await staking.getTotalAlphaStaked(hotkey, netuid);
    console.log("alphaAfter:", alphaAfter.toString());
  } catch (e) {
    fail("post-addStake getTotalAlphaStaked failed: " + fmtErr(e));
  }

  const alphaReceived = alphaAfter > alphaBefore ? alphaAfter - alphaBefore : 0n;
  console.log("alphaReceived:", alphaReceived.toString());
  if (alphaReceived === 0n) {
    console.log("No alpha increase detected, skipping burnAlpha.");
    return;
  }

  try {
    const gas = await staking.burnAlpha.estimateGas(hotkey, alphaReceived, netuid);
    console.log("burnAlpha estimateGas:", gas.toString());
  } catch (e) {
    fail("burnAlpha estimateGas failed: " + fmtErr(e));
  }

  console.log("Calling burnAlpha...");
  try {
    const tx = await staking.burnAlpha(hotkey, alphaReceived, netuid);
    const rcpt = await tx.wait();
    console.log("burnAlpha tx:", tx.hash, "status:", rcpt.status);
  } catch (e) {
    fail("burnAlpha failed: " + fmtErr(e));
  }

  const alphaFinal = await staking.getTotalAlphaStaked(hotkey, netuid);
  console.log("alphaFinal:", alphaFinal.toString());
  console.log("Done.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
