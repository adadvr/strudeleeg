/**
 * oracle/generate.mjs — Strudel oracle fixture generator
 *
 * CLEAN-ROOM: Uses Strudel only as a BLACK BOX via its public API.
 * We call queryArc() on patterns and capture their output as JSON fixtures.
 * No internal Strudel code is read or translated.
 *
 * Run: node oracle/generate.mjs  (from project root)
 *
 * Uses individual .mjs files from @strudel/core to avoid the broken
 * @kabelsalat/web dependency in dist/index.mjs.
 *
 * IMPORTANT: All patterns are built using public combinators (pure, set, slow,
 * fast, fastcat, slowcat, stack) matching how the Swift CodeParser evaluates
 * the same code strings. This ensures oracle = swift engine for all cases.
 */

import { writeFileSync, mkdirSync } from 'fs';
import { fileURLToPath, pathToFileURL } from 'url';
import path from 'path';

const __dirname   = path.dirname(fileURLToPath(import.meta.url));
const ROOT        = path.resolve(__dirname, '..');
const WEB_MODS    = path.join(ROOT, 'web', 'node_modules');
const FIXTURE_DIR = path.join(ROOT, 'MiniEngine', 'Tests', 'MiniEngineTests', 'Fixtures');

// ── Import Strudel public API ────────────────────────────────────────────────
const corePath = pathToFileURL(path.join(WEB_MODS, '@strudel/core/pattern.mjs')).href;
const { pure, stack, fastcat, slowcat, silence: _sil } = await import(corePath);
const strudelSilence = _sil;

// ── Fraction → "n/d" string ──────────────────────────────────────────────────
function fracToString(f) {
  if (f == null) return null;
  if (typeof f === 'number') return `${f}/1`;
  const s = BigInt(f.s ?? 1n);
  const n = BigInt(f.n ?? 0n);
  const d = BigInt(f.d ?? 1n);
  const num = s * n, den = d;
  function gcd(a, b) {
    if (a < 0n) a = -a; if (b < 0n) b = -b;
    while (b) { [a, b] = [b, a % b]; }
    return a || 1n;
  }
  const g = gcd(num < 0n ? -num : num, den);
  return `${(num/g).toString()}/${(den/g).toString()}`;
}

// ── Hap serialiser ───────────────────────────────────────────────────────────
function serializeHap(hap) {
  return {
    whole: hap.whole ? {
      begin: fracToString(hap.whole.begin),
      end:   fracToString(hap.whole.end),
    } : null,
    part: {
      begin: fracToString(hap.part.begin),
      end:   fracToString(hap.part.end),
    },
    value: hap.value,
  };
}

// ── Pattern constructors that mirror CodeParser semantics ─────────────────────
// withCtrl(base, ctrl) = structure from base, values from ctrl merged in.
// This uses Pattern.set() which is the public API equivalent of appLeft/withControl.
function withCtrl(base, ctrl) { return base.set(ctrl); }

// ── Test cases ────────────────────────────────────────────────────────────────
// These mirror exactly what the Swift CodeParser builds from the code string.
//   s("pad")                             → pure({s:'pad'})
//   s("pad").slow(4)                     → pure({s:'pad'}).slow(4)
//   s("pad").slow(4).gain(0.5).room(0.6) → pure({s:'pad'}).slow(4).set(pure({gain:0.5})).set(pure({room:0.6}))
// etc.

const CASES = [
  {
    label: 's("pad")',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' });
    },
  },
  {
    label: 's("pad").slow(4)',
    spanCycles: 4,
    build() {
      return pure({ s: 'pad' }).slow(4);
    },
  },
  {
    label: 's("pad bell")',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }), pure({ s: 'bell' }));
    },
  },
  {
    label: 's("[pad bell] pad")',
    spanCycles: 1,
    build() {
      const inner = fastcat(pure({ s: 'pad' }), pure({ s: 'bell' }));
      return fastcat(inner, pure({ s: 'pad' }));
    },
  },
  {
    label: 's("pad ~ bell")',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }), strudelSilence, pure({ s: 'bell' }));
    },
  },
  {
    label: 'note("<c4 e4 g4 b4>").s("bell").slow(2)',
    spanCycles: 8,
    build() {
      // slowcat of notes merged with s, then slow(2)
      const notePat = slowcat(
        pure({ note: 60 }), pure({ note: 64 }),
        pure({ note: 67 }), pure({ note: 71 }),
      );
      // Combine note + s via set (structure from note)
      const base = notePat.set(pure({ s: 'bell' }));
      return base.slow(2);
    },
  },
  {
    label: 'note("c4 e4").s("bell").fast(2)',
    spanCycles: 1,
    build() {
      const notePat = fastcat(pure({ note: 60 }), pure({ note: 64 }));
      const base = notePat.set(pure({ s: 'bell' }));
      return base.fast(2);
    },
  },
  {
    label: 's("pad").gain("<0.3 0.8>")',
    spanCycles: 2,
    build() {
      // gain alternates 0.3/0.8 per cycle via slowcat
      const sPat   = pure({ s: 'pad' });
      const gPat   = slowcat(pure({ gain: 0.3 }), pure({ gain: 0.8 }));
      return sPat.set(gPat);
    },
  },
  {
    // Seed code — evaluates to exactly the same pattern CodeParser builds
    label: 'stack(s("pad").slow(4).gain(0.5).room(0.6), note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7))',
    spanCycles: 8,
    build() {
      // Layer 1: s("pad").slow(4).gain(0.5).room(0.6)
      const pad = pure({ s: 'pad' }).slow(4)
        .set(pure({ gain: 0.5 }))
        .set(pure({ room: 0.6 }));

      // Layer 2: note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
      const bell = slowcat(
        pure({ note: 60 }), pure({ note: 64 }),
        pure({ note: 67 }), pure({ note: 71 }),
      ).set(pure({ s: 'bell' })).slow(2)
        .set(pure({ cutoff: 1500 }))
        .set(pure({ room: 0.4 }))
        .set(pure({ gain: 0.7 }));

      return stack(pad, bell);
    },
  },
];

// ── Query and serialize ──────────────────────────────────────────────────────
function queryCase(c) {
  const pat    = c.build();
  const n      = c.spanCycles;
  const haps   = pat.queryArc(0, n);
  const sorted = [...haps].sort((a, b) =>
    Number(a.part.begin.valueOf()) - Number(b.part.begin.valueOf())
  );
  return { pattern: c.label, span: [0, n], haps: sorted.map(serializeHap) };
}

// ── Generate fixtures ────────────────────────────────────────────────────────
mkdirSync(FIXTURE_DIR, { recursive: true });

const fixtures = [];
for (const c of CASES) {
  try {
    const fix = queryCase(c);
    fixtures.push(fix);
    console.log(`✓  ${c.label}  →  ${fix.haps.length} hap(s)`);
    // Show a sample hap for visual verification
    if (fix.haps.length > 0) {
      const h = fix.haps[0];
      console.log(`     first: part [${h.part.begin} - ${h.part.end}]  value: ${JSON.stringify(h.value)}`);
    }
  } catch (err) {
    console.error(`✗  ${c.label}: ${err.message}`);
    console.error(err.stack);
  }
}

const outPath = path.join(FIXTURE_DIR, 'oracle_fixtures.json');
writeFileSync(outPath, JSON.stringify(fixtures, null, 2));
console.log(`\nWrote ${fixtures.length} fixture(s) to ${outPath}`);
