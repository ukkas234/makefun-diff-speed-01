// Fast drop-in for makefun-diff 1.0.0 (MIT): exact same patch, much less work.
//
// Idea: intern every distinct line once (a line becomes one integer, so the
// search compares ints, never strings), trim the common prefix/suffix, then
// run Myers's greedy search exactly as makefun-diff defines it — furthest
// point per diagonal, deletion wins a tie, no edge pruning, snakes followed
// to the end — in hand-written WebAssembly (solve.wat -> solve.wasm), with
// the pure-JS search below as fallback. The patch is then built from the
// runs with the same hunk rule (3 lines of context, runs at most 6 kept
// lines apart share a hunk, deletions before insertions, "%" after a line
// with no newline).

import { readFileSync } from 'node:fs';

const NO_NL = 0x40000000; // bit marking a last line that ends with no newline
const KEEP = 0;
const DEL = 1;
const INS = 2;

// The Myers search also exists as hand-written WebAssembly (solve.wat,
// assembled by tools/wat.cjs into solve.wasm): the same greedy rule, but
// the O(D^2) search runs at native speed instead of in JavaScript. The
// pure-JS search below stays as the fallback (and for tiny inputs).
const WASM_B = 0x40000;
const WASM_OUT = 0x80000;
const WASM_MAX_LINES = 60000;
let wasm = undefined; // undefined = not tried yet, false = unavailable
function getWasm() {
  if (wasm !== undefined) return wasm;
  try {
    const bytes = readFileSync(new URL('./solve.wasm', import.meta.url));
    const mod = new WebAssembly.Module(bytes);
    wasm = new WebAssembly.Instance(mod, {}).exports;
  } catch {
    wasm = false;
  }
  return wasm;
}
/** The edit runs of a[a0..a1) into b[b0..b1), via WebAssembly; null on failure. */
function editRunsWasm(A, a0, a1, B, b0, b1) {
  const N = a1 - a0;
  const M = b1 - b0;
  if (N <= 0 || M <= 0 || N > WASM_MAX_LINES || M > WASM_MAX_LINES) return null;
  const w = getWasm();
  if (!w) return null;
  // A fresh view each call: a memory.grow inside search detaches the old one.
  const view = new Int32Array(w.mem.buffer);
  view.set(A.subarray(a0, a1), 0);
  view.set(B.subarray(b0, b1), WASM_B >> 2);
  const count = w.search(0, N, WASM_B, M, WASM_OUT);
  if (count < 0) return null; // trace would not fit in memory
  const out = new Int32Array(w.mem.buffer);
  const base = WASM_OUT >> 2;
  const runs = [];
  for (let i = 0; i < count; i++) runs.push([out[base + 2 * i], out[base + 2 * i + 1]]);
  return runs;
}

/** Distinct line strings, shared by both texts of a case (and across cases). */
const interned = new Map();
function intern(s) {
  let id = interned.get(s);
  if (id === undefined) {
    id = interned.size;
    interned.set(s, id);
  }
  return id;
}

/**
 * A text's lines as integer ids, each line's trailing newline folded into
 * the id only where it can differ: every line but the last ends with one,
 * so only a last line without one needs its own mark.
 * Returns { ids, parts, bare, n } where parts are the split strings.
 */
function linesOf(text) {
  const parts = text.split('\n');
  const last = parts.length - 1;
  const bare = parts[last] !== '';
  const n = bare ? parts.length : last;
  const ids = new Int32Array(n);
  for (let i = 0; i < n - 1; i++) ids[i] = intern(parts[i]);
  if (n > 0) {
    const id = intern(parts[n - 1]);
    ids[n - 1] = bare ? id | NO_NL : id;
  }
  return { ids, parts, bare, n };
}

/** One flat trace of furthest points: round d, diagonal j holds its x. */
let trace = new Int32Array(1 << 16);
let traceCap = 1 << 16;

/**
 * The edit runs of a[a0..a1) into b[b0..b1) as [kind, count] pairs, by the
 * exact greedy rule: furthest point per diagonal, deletion wins a tie.
 * Runs are returned in order, adjacent runs of one kind already merged.
 */
function editRuns(A, a0, a1, B, b0, b1) {
  const N = a1 - a0;
  const M = b1 - b0;
  if (N === 0) return M === 0 ? [] : [[INS, M]];
  if (M === 0) return [[DEL, N]];
  const AA = A.subarray(a0, a1);
  const BB = B.subarray(b0, b1);

  // The trace lives in one flat array; round d holds d+1 entries at
  // offset d*(d+1)/2, diagonal k = 2j-d at index j. Grow it as needed.
  let T = trace;
  let cap = traceCap;
  const ensure = (d) => {
    const need = ((d * (d + 1)) >> 1) + d + 1;
    if (need <= cap) return;
    let c = cap;
    while (c < need) c *= 2;
    const next = new Int32Array(c);
    next.set(T.subarray(0, cap));
    T = next;
    cap = c;
  };

  // Round 0: the seed snake on diagonal 0.
  let x = 0;
  let y = 0;
  while (x < N && y < M && AA[x] === BB[y]) {
    x++;
    y++;
  }
  ensure(0);
  T[0] = x;
  if (x === N && y === M) {
    trace = T;
    traceCap = cap;
    return [[KEEP, x]];
  }

  let D = -1;
  let endJ = 0;
  outer: for (let d = 1; ; d++) {
    ensure(d);
    const prevOff = ((d - 1) * d) >> 1;
    const curOff = (d * (d + 1)) >> 1;
    let k = -d;
    for (let j = 0; j <= d; j++, k += 2) {
      let xDel = -1;
      let xIns = -1;
      if (j > 0) {
        const px = T[prevOff + j - 1];
        if (px >= 0 && px < N) xDel = px + 1;
      }
      if (j < d) {
        const px = T[prevOff + j];
        if (px >= 0 && px - k <= M) xIns = px;
      }
      let nx;
      if (xDel >= xIns) {
        if (xDel < 0) {
          T[curOff + j] = -1;
          continue;
        }
        nx = xDel;
      } else {
        nx = xIns;
      }
      let ny = nx - k;
      while (nx < N && ny < M && AA[nx] === BB[ny]) {
        nx++;
        ny++;
      }
      T[curOff + j] = nx;
      if (nx === N && ny === M) {
        D = d;
        endJ = j;
        break outer;
      }
    }
  }
  trace = T;
  traceCap = cap;

  // Walk the trace back, collecting (in reverse) each round's snake and move.
  const segs = [];
  let j = endJ;
  x = N;
  y = M;
  for (let d = D; d >= 1; d--) {
    const k = 2 * j - d;
    const prevOff = ((d - 1) * d) >> 1;
    let pxDel = -1;
    let pxIns = -1;
    if (j > 0) pxDel = T[prevOff + j - 1];
    if (j < d) pxIns = T[prevOff + j];
    const delOk = pxDel >= 0 && pxDel < N;
    const insOk = pxIns >= 0 && pxIns - k <= M;
    const delX = delOk ? pxDel + 1 : -1;
    const insX = insOk ? pxIns : -1;
    if (delX >= insX) {
      const snake = x - (pxDel + 1);
      if (snake > 0) segs.push([KEEP, snake]);
      segs.push([DEL, 1]);
      x = pxDel;
      y = pxDel - (k - 1);
      j = j - 1;
    } else {
      const snake = x - pxIns;
      if (snake > 0) segs.push([KEEP, snake]);
      segs.push([INS, 1]);
      x = pxIns;
      y = pxIns - (k + 1);
    }
  }
  if (x > 0) segs.push([KEEP, x]);

  // Reverse into forward order, merging runs of one kind.
  const runs = [];
  for (let i = segs.length - 1; i >= 0; i--) {
    const [kind, count] = segs[i];
    const last = runs.length > 0 ? runs[runs.length - 1] : undefined;
    if (last !== undefined && last[0] === kind) last[1] += count;
    else runs.push([kind, count]);
  }
  return runs;
}

/** A line as the patch writes it (its op, the line, "%" when it had no newline). */
function written(op, part, hasNl) {
  return hasNl ? op + part + '\n' : op + part + '\n%\n';
}

/** makefun-diff 1.0.0's answer for one case's input { old, new }. */
export function run(input) {
  if (input === null || typeof input !== 'object' || typeof input.old !== 'string' || typeof input.new !== 'string') {
    throw new TypeError('makefun-diff: the input is { old, new }, two strings');
  }
  const a = linesOf(input.old);
  const b = linesOf(input.new);
  const n = a.n;
  const m = b.n;

  // Common prefix, then common suffix of what is left.
  let prefix = 0;
  while (prefix < n && prefix < m && a.ids[prefix] === b.ids[prefix]) prefix++;
  let suffix = 0;
  while (suffix < n - prefix && suffix < m - prefix && a.ids[n - 1 - suffix] === b.ids[m - 1 - suffix]) suffix++;

  const runs = [];
  if (prefix > 0) runs.push([KEEP, prefix]);
  const mid = editRunsWasm(a.ids, prefix, n - suffix, b.ids, prefix, m - suffix)
    ?? editRuns(a.ids, prefix, n - suffix, b.ids, prefix, m - suffix);
  for (let i = 0; i < mid.length; i++) runs.push(mid[i]);
  if (suffix > 0) runs.push([KEEP, suffix]);

  // Change runs: stretches of deletions and insertions between kept lines.
  const changes = [];
  let o = 0;
  let p = 0;
  let deleted = 0;
  let inserted = 0;
  for (let i = 0; i < runs.length; i++) {
    const kind = runs[i][0];
    const count = runs[i][1];
    if (kind === KEEP) {
      o += count;
      p += count;
      continue;
    }
    let c = changes.length > 0 ? changes[changes.length - 1] : undefined;
    if (c === undefined || c.o + c.dels !== o || c.p + c.ins !== p) {
      c = { o, p, dels: 0, ins: 0 };
      changes.push(c);
    }
    if (kind === DEL) {
      c.dels += count;
      o += count;
      deleted += count;
    } else {
      c.ins += count;
      p += count;
      inserted += count;
    }
  }

  // Hunks: change runs at most 6 kept lines apart share one.
  const hunks = [];
  for (let i = 0; i < changes.length; i++) {
    const c = changes[i];
    const h = hunks.length > 0 ? hunks[hunks.length - 1] : undefined;
    const prev = h !== undefined ? h[h.length - 1] : undefined;
    if (prev !== undefined && c.o - (prev.o + prev.dels) <= 6) h.push(c);
    else hunks.push([c]);
  }

  const out = [`makefun-diff/1 old=${n} new=${m} hunks=${hunks.length} deleted=${deleted} inserted=${inserted}\n`];
  for (let hi = 0; hi < hunks.length; hi++) {
    const h = hunks[hi];
    const first = h[0];
    const last = h[h.length - 1];
    const oldStart = Math.max(0, first.o - 3);
    const newStart = first.p - (first.o - oldStart);
    const after = Math.min(3, n - (last.o + last.dels));
    const oldEnd = last.o + last.dels + after;
    const newEnd = last.p + last.ins + after;
    out.push(`@ ${oldStart + 1} ${oldEnd - oldStart} ${newStart + 1} ${newEnd - newStart}\n`);
    let at = oldStart;
    for (let ci = 0; ci < h.length; ci++) {
      const c = h[ci];
      for (; at < c.o; at++) out.push(written('=', a.parts[at], at < n - 1 || !a.bare));
      for (let t = 0; t < c.dels; t++) out.push(written('-', a.parts[c.o + t], c.o + t < n - 1 || !a.bare));
      for (let t = 0; t < c.ins; t++) out.push(written('+', b.parts[c.p + t], c.p + t < m - 1 || !b.bare));
      at = c.o + c.dels;
    }
    for (; at < oldEnd; at++) out.push(written('=', a.parts[at], at < n - 1 || !a.bare));
  }
  return out.join('');
}
