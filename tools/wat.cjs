// Minimal WAT assembler (subset) — written from scratch for this project.
// Parses a small subset of WebAssembly text format and emits a .wasm binary.
// Supported: (module (memory ...) (global ...) (func ...) (export ...)),
// i32 arithmetic/comparisons, locals/globals, i32.load/store, memory.size/grow,
// block/loop/if/else/br/br_if/return/call/drop/select/unreachable/nop.
// Usage: node tools/wat.cjs in.wat out.wasm
'use strict';
const fs = require('node:fs');

const VALTYPE = { i32: 0x7f, i64: 0x7e, f32: 0x7d, f64: 0x7c };

// ---------- tokenizer ----------
function tokenize(src) {
  const toks = [];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === ' ' || c === '\t' || c === '\r' || c === '\n') { i++; continue; }
    if (c === ';' && src[i + 1] === ';') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '(') { toks.push({ t: 'lp' }); i++; continue; }
    if (c === ')') { toks.push({ t: 'rp' }); i++; continue; }
    if (c === '"') {
      let s = '';
      i++;
      while (i < n && src[i] !== '"') {
        if (src[i] === '\\' && i + 1 < n) {
          const e = src[i + 1];
          if (e === 'n') s += '\n';
          else if (e === 't') s += '\t';
          else if (e === 'r') s += '\r';
          else if (e === '"') s += '"';
          else if (e === '\\') s += '\\';
          else if (e === 'u' && src[i + 2] === '{') {
            const j = src.indexOf('}', i + 3);
            s += String.fromCodePoint(parseInt(src.slice(i + 3, j), 16));
            i = j + 1;
            continue;
          } else s += e;
          i += 2;
        } else { s += src[i]; i++; }
      }
      i++; // closing quote
      toks.push({ t: 'str', v: s });
      continue;
    }
    let j = i;
    while (j < n && !' \t\r\n()"'.includes(src[j])) j++;
    toks.push({ t: 'atom', v: src.slice(i, j) });
    i = j;
  }
  return toks;
}

// ---------- parser: nested arrays; atoms are strings, strings are {str} ----------
function parse(toks) {
  let p = 0;
  function expr() {
    const tk = toks[p++];
    if (!tk) throw new Error('unexpected end of input');
    if (tk.t === 'lp') {
      const list = [];
      while (p < toks.length && toks[p].t !== 'rp') list.push(expr());
      if (p >= toks.length) throw new Error('unbalanced parens');
      p++; // consume ')'
      return list;
    }
    if (tk.t === 'str') return { str: tk.v };
    return tk.v;
  }
  const forms = [];
  while (p < toks.length) forms.push(expr());
  return forms;
}

// ---------- LEB128 ----------
function uleb(v) {
  const out = [];
  v = Math.floor(v);
  do {
    let b = v & 0x7f;
    v = Math.floor(v / 128);
    if (v) b |= 0x80;
    out.push(b);
  } while (v);
  return out;
}
function sleb(v) {
  const out = [];
  v = Math.floor(v);
  for (;;) {
    let b = v & 0x7f;
    v = Math.floor(v / 128);
    // sign bit of the byte vs sign of remaining value
    const sign = b & 0x40;
    if ((v === 0 && !sign) || (v === -1 && sign)) {
      out.push(b);
      break;
    }
    out.push(b | 0x80);
  }
  return out;
}
function parseNum(s) {
  s = s.replace(/_/g, '');
  let neg = false;
  if (s.startsWith('+')) s = s.slice(1);
  else if (s.startsWith('-')) { neg = true; s = s.slice(1); }
  let v;
  if (s.startsWith('0x') || s.startsWith('0X')) v = parseInt(s.slice(2), 16);
  else v = parseInt(s, 10);
  if (Number.isNaN(v)) throw new Error('bad number: ' + s);
  return neg ? -v : v;
}
function i32s(v) {
  v = Math.trunc(v) & 0xffffffff;
  if (v >= 0x80000000) v -= 0x100000000;
  return v;
}

// ---------- opcodes ----------
const OP = {
  unreachable: [0x00], nop: [0x01],
  block: [0x02], loop: [0x03], if: [0x04], else: [0x05],
  br: [0x0c], br_if: [0x0d], return: [0x0f],
  call: [0x10], drop: [0x1a], select: [0x1b],
  'local.get': [0x20], 'local.set': [0x21], 'local.tee': [0x22],
  'global.get': [0x23], 'global.set': [0x24],
  'i32.load': [0x28], 'i32.store': [0x36],
  'memory.size': [0x3f, 0x00], 'memory.grow': [0x40, 0x00],
  'i32.const': [0x41],
  'i32.eqz': [0x45], 'i32.eq': [0x46], 'i32.ne': [0x47],
  'i32.lt_s': [0x48], 'i32.lt_u': [0x49], 'i32.gt_s': [0x4a], 'i32.gt_u': [0x4b],
  'i32.le_s': [0x4c], 'i32.le_u': [0x4d], 'i32.ge_s': [0x4e], 'i32.ge_u': [0x4f],
  'i32.add': [0x6a], 'i32.sub': [0x6b], 'i32.mul': [0x6c],
  'i32.div_s': [0x6d], 'i32.rem_s': [0x6f],
  'i32.and': [0x71], 'i32.or': [0x72], 'i32.xor': [0x73],
  'i32.shl': [0x74], 'i32.shr_s': [0x75], 'i32.shr_u': [0x76],
};

function section(id, payload) {
  return [id, ...uleb(payload.length), ...payload];
}
function vec(items) {
  const out = [...uleb(items.length)];
  for (const it of items) out.push(...it);
  return out;
}
function nameBytes(s) {
  const b = Buffer.from(s, 'utf8');
  return [...uleb(b.length), ...b];
}

// ---------- assembler ----------
function assemble(src) {
  const forms = parse(tokenize(src));
  if (forms.length !== 1 || !Array.isArray(forms[0]) || forms[0][0] !== 'module') {
    throw new Error('expected a single (module ...) form');
  }
  const mod = forms[0].slice(1);

  // Collect module fields.
  const memories = [];
  const globals = [];
  const funcs = [];
  const exports = [];
  for (const f of mod) {
    if (!Array.isArray(f)) throw new Error('unexpected top-level atom: ' + f);
    switch (f[0]) {
      case 'memory': {
        let name = null;
        let idx = 1;
        if (typeof f[1] === 'string' && f[1].startsWith('$')) { name = f[1]; idx = 2; }
        // inline export?
        let ex = null;
        let j = idx;
        if (Array.isArray(f[j]) && f[j][0] === 'export') { ex = f[j][1].str; j++; }
        const min = parseNum(f[j]);
        const max = f[j + 1] !== undefined ? parseNum(f[j + 1]) : null;
        memories.push({ name, min, max });
        if (ex) exports.push({ name: ex, kind: 0x02, index: memories.length - 1 });
        break;
      }
      case 'global': {
        let name = null;
        let idx = 1;
        if (typeof f[1] === 'string' && f[1].startsWith('$')) { name = f[1]; idx = 2; }
        let ex = null;
        let j = idx;
        if (Array.isArray(f[j]) && f[j][0] === 'export') { ex = f[j][1].str; j++; }
        // (mut i32) or i32
        let mut = false;
        let type = null;
        if (Array.isArray(f[j]) && f[j][0] === 'mut') { mut = true; type = f[j][1]; j++; }
        else { type = f[j]; j++; }
        const init = f[j];
        globals.push({ name, type, mut, init });
        if (ex) exports.push({ name: ex, kind: 0x03, index: globals.length - 1 });
        break;
      }
      case 'func': {
        funcs.push(f);
        break;
      }
      case 'export': {
        const nm = f[1].str;
        const target = f[2];
        let kind;
        if (target[0] === 'func') kind = 0x00;
        else if (target[0] === 'memory') kind = 0x02;
        else if (target[0] === 'global') kind = 0x03;
        else throw new Error('unsupported export target ' + target[0]);
        exports.push({ name: nm, kind, ref: target[1] });
        break;
      }
      default:
        throw new Error('unsupported top-level form: ' + f[0]);
    }
  }

  // Resolve func names and inline exports inside funcs.
  const funcNameToIdx = new Map();
  funcs.forEach((f, i) => {
    let idx = 1;
    if (typeof f[1] === 'string' && f[1].startsWith('$')) funcNameToIdx.set(f[1], i);
    for (const child of f.slice(1)) {
      if (Array.isArray(child) && child[0] === 'export') {
        exports.push({ name: child[1].str, kind: 0x00, index: i });
      }
    }
  });
  for (const e of exports) {
    if (e.ref !== undefined) {
      if (typeof e.ref === 'string' && e.ref.startsWith('$')) {
        if (e.kind === 0x00) e.index = funcNameToIdx.get(e.ref);
        else throw new Error('named export target not supported for kind ' + e.kind);
      } else e.index = parseNum(String(e.ref));
      delete e.ref;
    }
  }
  const globalNameToIdx = new Map();
  globals.forEach((g, i) => { if (g.name) globalNameToIdx.set(g.name, i); });

  // Parse each func: params, results, locals, body.
  const parsedFuncs = funcs.map((f) => {
    let name = null;
    let i = 1;
    if (typeof f[i] === 'string' && f[i].startsWith('$')) { name = f[i]; i++; }
    const params = [];
    const results = [];
    const locals = [];
    const body = [];
    for (; i < f.length; i++) {
      const c = f[i];
      if (!Array.isArray(c)) throw new Error('unexpected func child: ' + c);
      if (c[0] === 'export') continue;
      if (c[0] === 'param') {
        // (param $a i32) or (param i32 i32) or (param $a i32 $b i32)
        for (let k = 1; k < c.length; k++) {
          if (typeof c[k] === 'string' && c[k].startsWith('$')) {
            params.push({ name: c[k], type: c[k + 1] });
            k++;
          } else params.push({ name: null, type: c[k] });
        }
      } else if (c[0] === 'result') {
        for (let k = 1; k < c.length; k++) results.push(c[k]);
      } else if (c[0] === 'local') {
        for (let k = 1; k < c.length; k++) {
          if (typeof c[k] === 'string' && c[k].startsWith('$')) {
            locals.push({ name: c[k], type: c[k + 1] });
            k++;
          } else locals.push({ name: null, type: c[k] });
        }
      } else {
        body.push(c);
      }
    }
    return { name, params, results, locals, body };
  });

  // Types.
  const typeMap = new Map();
  const types = [];
  const funcTypeIdx = parsedFuncs.map((pf) => {
    const key = pf.params.map((p) => p.type).join(',') + '->' + pf.results.join(',');
    if (!typeMap.has(key)) {
      typeMap.set(key, types.length);
      types.push({ params: pf.params.map((p) => p.type), results: pf.results });
    }
    return typeMap.get(key);
  });

  // Encode a function body.
  function encodeFunc(pf, fi) {
    const localIdx = new Map();
    const localTypes = [];
    [...pf.params, ...pf.locals].forEach((l, idx) => {
      if (l.name) localIdx.set(l.name, idx);
      localTypes.push(l.type);
    });
    const labels = []; // stack of label names (null for anonymous)
    const out = [];

    function localIndex(ref) {
      if (typeof ref === 'string' && ref.startsWith('$')) {
        const idx = localIdx.get(ref);
        if (idx === undefined) throw new Error('unknown local ' + ref);
        return idx;
      }
      return parseNum(String(ref));
    }
    function labelDepth(ref) {
      if (typeof ref === 'string' && ref.startsWith('$')) {
        const pos = labels.lastIndexOf(ref);
        if (pos < 0) throw new Error('unknown label ' + ref);
        return labels.length - 1 - pos;
      }
      return parseNum(String(ref));
    }
    function blockType(node) {
      // node children may include (result i32)
      for (const c of node.slice(1)) {
        if (Array.isArray(c) && c[0] === 'result') {
          if (c.length !== 2) throw new Error('multi-value block results not supported');
          return VALTYPE[c[1]];
        }
      }
      return 0x40;
    }

    function enc(node) {
      if (typeof node === 'string') {
        // bare zero-operand instruction
        if (node === 'unreachable') out.push(0x00);
        else if (node === 'nop') out.push(0x01);
        else throw new Error('unexpected bare atom in body: ' + node);
        return;
      }
      const op = node[0];
      if (op === 'block' || op === 'loop') {
        let li = 1;
        let label = null;
        if (typeof node[1] === 'string' && node[1].startsWith('$')) { label = node[1]; li = 2; }
        out.push(op === 'block' ? 0x02 : 0x03, blockType(node));
        labels.push(label);
        for (let k = li; k < node.length; k++) {
          if (Array.isArray(node[k]) && node[k][0] === 'result') continue;
          enc(node[k]);
        }
        labels.pop();
        out.push(0x0b);
        return;
      }
      if (op === 'if') {
        let cond = null;
        const thenBody = [];
        let elseBody = null;
        for (let k = 1; k < node.length; k++) {
          const c = node[k];
          if (Array.isArray(c) && c[0] === 'result') continue;
          if (Array.isArray(c) && c[0] === 'then') { thenBody.push(...c.slice(1)); continue; }
          if (Array.isArray(c) && c[0] === 'else') { elseBody = c.slice(1); continue; }
          if (cond) throw new Error('if with multiple conditions');
          cond = c;
        }
        if (!cond) throw new Error('if without condition');
        enc(cond);
        out.push(0x04, blockType(node));
        labels.push(null);
        for (const s of thenBody) enc(s);
        labels.pop();
        if (elseBody) {
          out.push(0x05);
          labels.push(null);
          for (const s of elseBody) enc(s);
          labels.pop();
        }
        out.push(0x0b);
        return;
      }
      // General folded instruction: encode array args first, then the op.
      let offset = null;
      let align = null;
      const atomArgs = [];
      for (let k = 1; k < node.length; k++) {
        const a = node[k];
        if (Array.isArray(a)) enc(a);
        else if (typeof a === 'string' && a.startsWith('offset=')) offset = parseNum(a.slice(7));
        else if (typeof a === 'string' && a.startsWith('align=')) align = parseNum(a.slice(6));
        else atomArgs.push(a);
      }
      switch (op) {
        case 'local.get': out.push(0x20, ...uleb(localIndex(atomArgs[0]))); return;
        case 'local.set': out.push(0x21, ...uleb(localIndex(atomArgs[0]))); return;
        case 'local.tee': out.push(0x22, ...uleb(localIndex(atomArgs[0]))); return;
        case 'global.get': {
          const idx = typeof atomArgs[0] === 'string' && atomArgs[0].startsWith('$')
            ? globalNameToIdx.get(atomArgs[0]) : parseNum(String(atomArgs[0]));
          out.push(0x23, ...uleb(idx));
          return;
        }
        case 'global.set': {
          const idx = typeof atomArgs[0] === 'string' && atomArgs[0].startsWith('$')
            ? globalNameToIdx.get(atomArgs[0]) : parseNum(String(atomArgs[0]));
          out.push(0x24, ...uleb(idx));
          return;
        }
        case 'br': out.push(0x0c, ...uleb(labelDepth(atomArgs[0]))); return;
        case 'br_if': out.push(0x0d, ...uleb(labelDepth(atomArgs[0]))); return;
        case 'call': {
          const idx = typeof atomArgs[0] === 'string' && atomArgs[0].startsWith('$')
            ? funcNameToIdx.get(atomArgs[0]) : parseNum(String(atomArgs[0]));
          out.push(0x10, ...uleb(idx));
          return;
        }
        case 'return': out.push(0x0f); return;
        case 'drop': out.push(0x1a); return;
        case 'select': out.push(0x1b); return;
        case 'memory.size': out.push(0x3f, 0x00); return;
        case 'memory.grow': out.push(0x40, 0x00); return;
        case 'i32.const': out.push(0x41, ...sleb(i32s(parseNum(String(atomArgs[0]))))); return;
        case 'i32.load': {
          const a = align === null ? 2 : align;
          out.push(0x28, ...uleb(a), ...uleb(offset === null ? 0 : offset));
          return;
        }
        case 'i32.store': {
          const a = align === null ? 2 : align;
          out.push(0x36, ...uleb(a), ...uleb(offset === null ? 0 : offset));
          return;
        }
        default: {
          const opc = OP[op];
          if (!opc) throw new Error('unsupported instruction: ' + op);
          out.push(...opc);
          return;
        }
      }
    }

    for (const s of pf.body) enc(s);
    // locals declaration: group consecutive same types (params excluded)
    const declTypes = pf.locals.map((l) => l.type);
    const groups = [];
    for (const t of declTypes) {
      const last = groups[groups.length - 1];
      if (last && last.type === t) last.count++;
      else groups.push({ type: t, count: 1 });
    }
    const localsVec = [...uleb(groups.length)];
    for (const g of groups) localsVec.push(...uleb(g.count), VALTYPE[g.type]);
    const bodyBytes = [...localsVec, ...out, 0x0b];
    return bodyBytes;
  }

  // Assemble sections.
  const out = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  // type section
  if (types.length) {
    out.push(...section(1, vec(types.map((t) => [
      0x60,
      ...uleb(t.params.length), ...t.params.map((p) => VALTYPE[p]),
      ...uleb(t.results.length), ...t.results.map((r) => VALTYPE[r]),
    ]))));
  }
  // func section
  if (parsedFuncs.length) {
    out.push(...section(3, vec(funcTypeIdx.map((i) => [...uleb(i)]))));
  }
  // memory section
  if (memories.length) {
    out.push(...section(5, vec(memories.map((m) => {
      if (m.max === null) return [0x00, ...uleb(m.min)];
      return [0x01, ...uleb(m.min), ...uleb(m.max)];
    }))));
  }
  // global section
  if (globals.length) {
    out.push(...section(6, vec(globals.map((g) => {
      // init expr: only (i32.const n) supported here
      const init = g.init;
      if (!Array.isArray(init) || init[0] !== 'i32.const') {
        throw new Error('only (i32.const n) global inits supported');
      }
      return [
        VALTYPE[g.type], g.mut ? 0x01 : 0x00,
        0x41, ...sleb(i32s(parseNum(String(init[1])))), 0x0b,
      ];
    }))));
  }
  // export section
  if (exports.length) {
    out.push(...section(7, vec(exports.map((e) => [
      ...nameBytes(e.name), e.kind, ...uleb(e.index),
    ]))));
  }
  // code section
  if (parsedFuncs.length) {
    out.push(...section(10, vec(parsedFuncs.map((pf, i) => {
      const body = encodeFunc(pf, i);
      return [...uleb(body.length), ...body];
    }))));
  }
  return Buffer.from(out);
}

const [,, inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error('usage: node tools/wat.cjs in.wat out.wasm');
  process.exit(2);
}
const src = fs.readFileSync(inPath, 'utf8');
const wasm = assemble(src);
fs.writeFileSync(outPath, wasm);
console.log(`wrote ${outPath}: ${wasm.length} bytes`);
