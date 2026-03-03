const hre = require("hardhat");
const readline = require("readline");

function askQuestion(question) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.toLowerCase().trim());
    });
  });
}

async function main() {
  console.log("\n========================================");
  console.log("   RPS Tournament Contract Deployment");
  console.log("========================================\n");

  console.log("Network:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);
  console.log("");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "TAO\n");

  console.log("RPS uses hash commit-reveal; drand via storage precompile (same as TAO_Colosseum).");
  console.log("Fees (1.5%): flushed to sn38 owner hotkey then burned via staking precompile (not withdrawable).\n");

  const sn38HotkeyHex = process.env.SN38_OWNER_HOTKEY;
  if (!sn38HotkeyHex || !/^0x[0-9a-fA-F]{64}$/.test(sn38HotkeyHex)) {
    console.error("SN38_OWNER_HOTKEY must be a 32-byte hex string (0x + 64 hex chars). Example: SN38_OWNER_HOTKEY=0x... npx hardhat run scripts/deploy-rps.js");
    process.exit(1);
  }
  const sn38OwnerHotkeyBytes32 = sn38HotkeyHex;

  const RPS = await hre.ethers.getContractFactory("RPS_Tournament");
  const deployTx = await RPS.getDeployTransaction(sn38OwnerHotkeyBytes32);

  console.log("Estimating gas for RPS_Tournament...\n");
  let estimatedGas;
  try {
    estimatedGas = await hre.ethers.provider.estimateGas({
      ...deployTx,
      from: deployer.address,
    });
  } catch (error) {
    console.error("Gas estimation failed:", error.message);
    estimatedGas = BigInt(4000000);
  }

  const feeData = await hre.ethers.provider.getFeeData();
  const gasPrice = feeData.gasPrice || hre.ethers.parseUnits("1", "gwei");
  const estimatedCost = estimatedGas * gasPrice;
  const gasLimitWithBuffer = (estimatedGas * BigInt(120)) / BigInt(100);
  const maxCost = gasLimitWithBuffer * gasPrice;

  console.log("========== GAS ESTIMATION ==========");
  console.log("Estimated gas:", estimatedGas.toString());
  console.log("Current gas price:", hre.ethers.formatUnits(gasPrice, "gwei"), "gwei");
  console.log("Estimated cost:", hre.ethers.formatEther(estimatedCost), "TAO");
  console.log("====================================\n");

  if (balance < maxCost) {
    console.log("⚠️  WARNING: Balance may be insufficient for RPS_Tournament deploy.\n");
  }

  const autoYes = process.argv.includes("--yes") || process.argv.includes("-y") || process.env.DEPLOY_AUTO_YES === "1";
  if (!autoYes) {
    const answer = await askQuestion("Proceed with RPS_Tournament deployment? (yes/no): ");
    if (answer !== "yes" && answer !== "y") {
      console.log("\n❌ Deployment cancelled.\n");
      process.exit(0);
    }
  }

  console.log("\n🚀 Deploying RPS_Tournament...\n");

  const rps = await RPS.deploy(sn38OwnerHotkeyBytes32, {
    gasLimit: gasLimitWithBuffer,
    gasPrice: gasPrice,
  });

  console.log("Transaction hash:", rps.deploymentTransaction().hash);
  console.log("Waiting for confirmation...\n");

  await rps.waitForDeployment();
  const address = await rps.getAddress();

  const receipt = await rps.deploymentTransaction().wait();
  const actualCost = receipt.gasUsed * gasPrice;

  console.log("========== DEPLOYMENT SUCCESS ==========");
  console.log("✅ RPS_Tournament deployed!");
  console.log("");
  console.log("Contract Address:", address);
  console.log("Network:", hre.network.name);
  console.log("Gas used:", receipt.gasUsed.toString());
  console.log("Actual cost:", hre.ethers.formatEther(actualCost), "TAO");
  console.log("=========================================\n");

  console.log("MIN_ENTRY:", hre.ethers.formatEther(await rps.MIN_ENTRY()), "TAO");
  console.log("sn38OwnerHotkey:", await rps.sn38OwnerHotkey());
  console.log("");
  console.log("DEPLOYED_RPS_ADDRESS=" + address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  });
