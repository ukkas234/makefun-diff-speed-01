// Regression test for the >32,768-runs overlap bug (Antigravity review §1.4).
// The WASM `out` region once ended at $segBase = 0xC0000, holding only
// 32,768 runs; a case emitting more runs overwrote unread backtrack
// segments and silently corrupted the patch. $segBase is now 0x280000
// (262,144 runs) and WASM memory is capped at 10240 pages (640 MiB).
//
// Usage: node test/stress-many-runs.mjs [path-to-baseline-index.js]
// The baseline defaults to the competition kit's makefun-diff 1.0.0 on
// this machine. NOT run by the grader; a developer check only.
import { run } from '../solve.js';
import { createRequire } from 'node:module';

const baselinePath = process.argv[2]
  ?? '/home/hatch/workspace/makefun/diff-speed-01-run-20261126-kit/diff-speed-01-run-20261126-kit/baselines/makefun-diff/vendor/makefun-diff/index.js';
const { diffPatch } = await import(baselinePath);

function alternating(n) {
  const oldLines = [];
  for (let i = 0; i < n; i++) oldLines.push('L' + i);
  const newLines = [];
  for (let i = 0; i < n; i += 2) newLines.push('L' + i);
  return { old: oldLines.join('\n') + '\n', new: newLines.join('\n') + '\n' };
}

let failed = 0;
for (const [name, n] of [['stress-A-32770', 32770], ['stress-B-35000', 35000]]) {
  // Stress A: 32,770 runs (> 32,768), D = 16,385 — past the WASM trace
  // cap (256 MiB), so search returns -1 and the checkpointed JS fallback
  // must answer it. Stress B: 35,000 runs, D = 17,500 — same fallback
  // path. Both must be byte-identical to the reference.
  const input = alternating(n);
  const mine = run(input);
  const ref = diffPatch(input);
  const ok = mine === ref;
  console.log(`${name}: ${ok ? 'PASS' : 'FAIL'} (runs > 32768, byte-identical: ${ok})`);
  if (!ok) failed++;
}
if (failed > 0) process.exit(1);
console.log('stress-many-runs: all pass');
