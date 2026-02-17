const hre = require("hardhat");
async function main() {
  const C = await hre.ethers.getContractFactory("TAOColosseum");
  const c = await C.deploy();
  await c.waitForDeployment();
  const h = await c.getBlake2b128ForRound(26145524);
  const hex = typeof h === "string" ? h : h && h.length === 32 ? "0x" + h.slice(2) : String(h);
  const hexClean = hex.replace(/^0x/, "").toLowerCase();
  console.log("Our BLAKE2b-128:", hexClean);
  console.log("Expected:      8e70ca71b63dde37a5a4f3d695002aab");
  console.log("Match:", hexClean === "8e70ca71b63dde37a5a4f3d695002aab");
  require("fs").writeFileSync("blake2b-out.txt", hexClean + "\nExpected: 8e70ca71b63dde37a5a4f3d695002aab\nMatch: " + (hexClean === "8e70ca71b63dde37a5a4f3d695002aab"));
}
main().catch(console.error);
