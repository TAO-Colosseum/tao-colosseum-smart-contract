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
  console.log("   TAO Colosseum Contract Deployment");
  console.log("========================================\n");
  
  console.log("Network:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);
  console.log("");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "TAO\n");

  // Get contract factory
  const TAOColosseum = await hre.ethers.getContractFactory("TAOColosseum");
  
  // Get deployment transaction for gas estimation
  const deployTx = await TAOColosseum.getDeployTransaction();
  
  // Estimate gas
  console.log("Estimating gas...\n");
  let estimatedGas;
  try {
    estimatedGas = await hre.ethers.provider.estimateGas({
      ...deployTx,
      from: deployer.address,
    });
  } catch (error) {
    console.error("Gas estimation failed:", error.message);
    console.log("Using fallback gas limit of 5,000,000");
    estimatedGas = BigInt(5000000);
  }
  
  // Get current gas price
  const feeData = await hre.ethers.provider.getFeeData();
  const gasPrice = feeData.gasPrice || hre.ethers.parseUnits("1", "gwei");
  
  // Calculate costs
  const estimatedCost = estimatedGas * gasPrice;
  const gasLimitWithBuffer = (estimatedGas * BigInt(120)) / BigInt(100); // 20% buffer
  const maxCost = gasLimitWithBuffer * gasPrice;
  
  console.log("========== GAS ESTIMATION ==========");
  console.log("Estimated gas:", estimatedGas.toString());
  console.log("Gas limit (with 20% buffer):", gasLimitWithBuffer.toString());
  console.log("Current gas price:", hre.ethers.formatUnits(gasPrice, "gwei"), "gwei");
  console.log("");
  console.log("Estimated cost:", hre.ethers.formatEther(estimatedCost), "TAO");
  console.log("Max cost (with buffer):", hre.ethers.formatEther(maxCost), "TAO");
  console.log("====================================\n");
  
  // Check if user has enough balance
  if (balance < maxCost) {
    console.log("⚠️  WARNING: Your balance may be insufficient!");
    console.log("   Balance:", hre.ethers.formatEther(balance), "TAO");
    console.log("   Max cost:", hre.ethers.formatEther(maxCost), "TAO\n");
  }
  
  // Ask for approval (skip if --yes or -y passed)
  const autoYes = process.argv.includes("--yes") || process.argv.includes("-y") || process.env.DEPLOY_AUTO_YES === "1";
  if (!autoYes) {
    const answer = await askQuestion("Do you want to proceed with deployment? (yes/no): ");
    if (answer !== "yes" && answer !== "y") {
      console.log("\n❌ Deployment cancelled by user.\n");
      process.exit(0);
    }
  }

  console.log("\n🚀 Deploying TAOColosseum...\n");
  
  // Deploy with optimized gas settings
  const taoColosseum = await TAOColosseum.deploy({
    gasLimit: gasLimitWithBuffer,
    gasPrice: gasPrice,
  });
  
  console.log("Transaction hash:", taoColosseum.deploymentTransaction().hash);
  console.log("Waiting for confirmation...\n");
  
  await taoColosseum.waitForDeployment();
  
  const address = await taoColosseum.getAddress();
  
  // Get actual gas used
  const receipt = await taoColosseum.deploymentTransaction().wait();
  const actualGasUsed = receipt.gasUsed;
  const actualCost = actualGasUsed * gasPrice;
  
  console.log("========== DEPLOYMENT SUCCESS ==========");
  console.log("✅ Contract deployed!");
  console.log("");
  console.log("Contract Address:", address);
  console.log("Network:", hre.network.name);
  console.log("Chain ID:", hre.network.config.chainId);
  console.log("");
  console.log("Gas used:", actualGasUsed.toString());
  console.log("Actual cost:", hre.ethers.formatEther(actualCost), "TAO");
  console.log("=========================================\n");

  // Verify initial state
  console.log("Verifying contract state...");
  const fee = await taoColosseum.PLATFORM_FEE();
  const minPool = await taoColosseum.MIN_POOL_SIZE();
  const bettingBlocks = await taoColosseum.BETTING_BLOCKS();
  const owner = await taoColosseum.owner();
  
  console.log("Owner:", owner);
  console.log("Platform Fee:", fee.toString(), "bps (", Number(fee) / 100, "%)");
  console.log("Min Pool Size:", hre.ethers.formatEther(minPool), "TAO");
  console.log("Betting Duration:", bettingBlocks.toString(), "blocks (~", Number(bettingBlocks) * 12 / 60, "minutes)\n");
  
  console.log("📋 Add this to your .env.local:");
  console.log(`NEXT_PUBLIC_CONTRACT_ADDRESS=${address}\n`);

  // Single line for scripts (e.g. verify)
  console.log("DEPLOYED_ADDRESS=" + address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  });
