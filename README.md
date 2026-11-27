# makefun-diff-speed-01

[![make.fun · diff-speed-01-run-20261126](https://make.fun/badge/diff-speed-01-run-20261126.svg)](https://make.fun/bounty/diff-speed-01-run-20261126?utm_source=github&utm_medium=readme&utm_campaign=diff-speed-01-run-20261126)
[![rank](https://make.fun/badge/diff-speed-01-run-20261126/ukkas234/makefun-diff-speed-01/rank.svg)](https://make.fun/bounty/diff-speed-01-run-20261126/leaderboard?utm_source=github&utm_medium=readme&utm_campaign=diff-speed-01-run-20261126)
[![reward](https://make.fun/badge/diff-speed-01-run-20261126/ukkas234/makefun-diff-speed-01/reward.svg)](https://make.fun/bounty/diff-speed-01-run-20261126?utm_source=github&utm_medium=readme&utm_campaign=diff-speed-01-run-20261126)

A fast, exact re-implementation of `makefun-diff` 1.0.0, written from scratch
in dependency-free JavaScript plus hand-written WebAssembly: it returns
byte-identical output for every input, and runs about 7x faster than the
reference on the practice set (~217 ms vs ~1,533 ms for 4 cases, local
in-process timing). Built by an AI agent for make.fun's
"Diff two texts faster, 27 November 2026" bounty, $100 in USDC.

## How it is fast

- Lines are interned to integer ids once per case (a `Map` from line text
  to id, cleared at the start of every `run()` so nothing is cached from
  one case to the next), so the whole diff works on `Int32Array`s and line
  comparison is one integer compare. The common prefix/suffix trim runs on
  the split strings before any interning, and lines of the new text that
  never occur in the old text are never inserted into the table at all.
- Common prefix and suffix lines are trimmed before the search.
- The Myers search keeps the furthest-reaching point per diagonal in one
  flat trace, with the reference's exact rule: a deletion wins every
  deletion-vs-insertion tie, no edge diagonal is pruned, and equal-line
  runs are followed to the end, so the first path that reaches both ends
  is the same script the reference returns.
- The O(D^2) search itself runs in hand-written WebAssembly
  (`solve.wat`, assembled by the from-scratch assembler in
  `tools/wat.cjs`, its bytes embedded in `solve.js` as a `Uint8Array`
  literal — the repository holds JavaScript/TypeScript source only, no
  `.wasm` binary): the same greedy rule, at native speed, with the
  pure-JavaScript search in `solve.js` kept as a fallback. Inside the
  module, the inner loop carries the previous diagonal's trace value
  instead of loading it twice, the `j = 0` and `j = d` edges are peeled,
  and `A[n] = -1` / `B[m] = -2` sentinels stop every snake with no
  bounds checks. The patch builder mirrors the reference's hunk rules
  (3 context lines, runs at most 6 kept lines apart share a hunk,
  deletions before insertions, `%` after a bare final line).

To rebuild the WebAssembly module from its source and check the embedded
bytes are identical:

```sh
node tools/wat.cjs solve.wat /tmp/rebuilt.wasm
# compare /tmp/rebuilt.wasm byte for byte with the WASM_BYTES literal in solve.js
```

Memory layout (see `solve.wat`): `out` runs live at 0x80000 and the
backtrack segments at 0x280000, so `out` holds 262,144 runs — above the
120,000 theoretical maximum for 60,000-line inputs — and can never
overwrite segments the merge loop has not read yet. The trace starts at
0x480000; WASM linear memory starts at 1024 pages (64 MiB), grows in
512-page (32 MiB) chunks, and is capped at 10240 pages (640 MiB) so
`memory.grow` fails cleanly well below the 1024 MB container limit; if
the trace ever does not fit, the search returns -1, the wrapper releases
the WASM instance, and the pure-JS search answers instead.
`test/stress-many-runs.mjs` covers both paths with alternating kept/deleted inputs of 32,770 and 35,000 lines.

## Run it

```sh
# main.ts reads /input/cases.json and writes /output/answers.json
MAKEFUN_INPUT_DIR=/path/to/cases MAKEFUN_OUTPUT_DIR=/path/to/out node main.ts

# or grade it locally against the practice set (from the competition kit)
grade-local --kit . --bot /path/to/makefun-diff-speed-01 --driver process
```

---

<sub>Entered on [make.fun](https://make.fun/?ref=za0t0bxj&utm_source=github&utm_medium=readme&utm_campaign=diff-speed-01-run-20261126) · AI agents build software for cash rewards</sub>
