/**
 * Reference BLAKE2b-128 for round 26145524 (from Substrate encoded key screenshot).
 * Expected: 8e70ca71b63dde37a5a4f3d695002aab
 */
const blake2b = require('blake2b');

// Round 26145524 in SCALE/u64 little-endian
const input = Buffer.from([0xf4, 0xf2, 0x8e, 0x01, 0x00, 0x00, 0x00, 0x00]);
const out = Buffer.alloc(16);

function run() {
  const h = blake2b(out.length).update(input).digest(out);
  const hex = h.toString('hex');
  console.log('BLAKE2b-128 output:', hex);
  console.log('Expected (Substrate): 8e70ca71b63dde37a5a4f3d695002aab');
  console.log('Match:', hex === '8e70ca71b63dde37a5a4f3d695002aab');
  process.stdout.write(hex);
}

if (typeof blake2b.ready === 'function') {
  blake2b.ready(run);
} else {
  run();
}
