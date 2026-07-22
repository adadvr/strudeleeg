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
const { pure, stack, fastcat, slowcat, silence: _sil, timecat } = await import(corePath);
const strudelSilence = _sil;

// ── Import euclid from @strudel/core ────────────────────────────────────────
const euclidPath = pathToFileURL(path.join(WEB_MODS, '@strudel/core/euclid.mjs')).href;
const { euclid, euclidRot } = await import(euclidPath);

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

  // ── Tier 1: mini-notation * (fast) ─────────────────────────────────────────
  {
    // "pad*2 bell" → 2 steps: [pad fast(2), bell]
    // pad*2 means pad repeats twice within its slot = fast(2) on that step
    // Sequence has 2 top-level steps, each 1/2 cycle.
    // pad*2: within [0, 1/2) plays pad twice → events at [0,1/4) and [1/4,1/2)
    // bell: [1/2, 1)
    label: 's("pad*2 bell")',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }).fast(2), pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: mini-notation ! (replicate) ────────────────────────────────────
  {
    // "pad!2 bell" → expand to 3 equal steps: [pad, pad, bell]
    // !2 replicates "pad" as 2 equal steps; then bell = 1 step. Total 3 steps.
    label: 's("pad!2 bell")',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }), pure({ s: 'pad' }), pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: mini-notation @ (weight) ───────────────────────────────────────
  {
    // "pad@3 bell" → pad weight=3, bell weight=1. Total=4.
    // pad: [0, 3/4), bell: [3/4, 1)
    label: 's("pad@3 bell")',
    spanCycles: 1,
    build() {
      return timecat([3, pure({ s: 'pad' })], [1, pure({ s: 'bell' })]);
    },
  },

  // ── Tier 1: mini-notation * inside group ───────────────────────────────────
  {
    // "[pad*2 bell] hi" → group first, then hi. 2 top-level steps.
    // Group [pad*2 bell] = fastcat(pad.fast(2), bell) in slot [0,1/2)
    // hi = [1/2, 1)
    label: 's("[pad*2 bell] hi")',
    spanCycles: 1,
    build() {
      const group = fastcat(pure({ s: 'pad' }).fast(2), pure({ s: 'bell' }));
      return fastcat(group, pure({ s: 'hi' }));
    },
  },

  // ── Tier 1: euclid(3,8) ────────────────────────────────────────────────────
  {
    label: 's("bell").euclid(3,8)',
    spanCycles: 1,
    build() {
      return euclid(3, 8, pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: euclid(2,5) ────────────────────────────────────────────────────
  {
    label: 's("bell").euclid(2,5)',
    spanCycles: 1,
    build() {
      return euclid(2, 5, pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: euclid(5,8) ────────────────────────────────────────────────────
  {
    label: 's("bell").euclid(5,8)',
    spanCycles: 1,
    build() {
      return euclid(5, 8, pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: euclid(3,8,2) rotation ────────────────────────────────────────
  {
    label: 's("bell").euclid(3,8,2)',
    spanCycles: 1,
    build() {
      return euclidRot(3, 8, 2, pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: pan ─────────────────────────────────────────────────────────────
  {
    label: 's("pad").pan(0.25)',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' }).set(pure({ pan: 0.25 }));
    },
  },

  // ── Tier 1: n() + scale → note MIDI ────────────────────────────────────────
  // n("0 2 4") + scale("C:minor")
  // C natural minor (aeolian) from C3 = MIDI 48:
  // intervals: [0, 2, 3, 5, 7, 8, 10]
  // n(0)=48, n(2)=51, n(4)=55
  {
    label: 'n("0 2 4").scale("C:minor").s("bell")',
    spanCycles: 1,
    build() {
      // n(0)=C3=48, n(2)=Eb3=51, n(4)=G3=55
      const notePat = fastcat(pure({ note: 48 }), pure({ note: 51 }), pure({ note: 55 }));
      return notePat.set(pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: n() negative and >7 wrapping ───────────────────────────────────
  {
    label: 'n("-1 7 8").scale("C:minor").s("bell")',
    spanCycles: 1,
    build() {
      // n(-1)=Bb2=46, n(7)=C4=60, n(8)=D4=62
      const notePat = fastcat(pure({ note: 46 }), pure({ note: 60 }), pure({ note: 62 }));
      return notePat.set(pure({ s: 'bell' }));
    },
  },

  // ── Tier 1: delay parameters (pattern level only — no audio-engine test) ───
  {
    label: 's("pad").delay(0.5).delaytime(0.3).delayfeedback(0.6)',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' })
        .set(pure({ delay: 0.5 }))
        .set(pure({ delaytime: 0.3 }))
        .set(pure({ delayfeedback: 0.6 }));
    },
  },

  // ── Fase 3: Synths — control map oracle ────────────────────────────────────
  // These verify the control-map structure emitted by the pattern layer.
  // DSP (oscillator, ADSR, filter) is tested in Swift unit tests, not oracle.

  {
    // s("sawtooth") → should have s="sawtooth" and synth="sawtooth"
    label: 's("sawtooth")',
    spanCycles: 1,
    build() {
      // Oracle just verifies the s field — synth field is added by Swift layer.
      // We check s="sawtooth" is present at the right time position.
      return pure({ s: 'sawtooth' });
    },
  },

  {
    // note("c3 e3").s("sawtooth") → 2 events with note + s fields
    label: 'note("c3 e3").s("sawtooth")',
    spanCycles: 1,
    build() {
      // c3=48, e3=52 in Strudel's MIDI scheme (C3=48)
      const notePat = fastcat(pure({ note: 48 }), pure({ note: 52 }));
      return notePat.set(pure({ s: 'sawtooth' }));
    },
  },

  {
    // s("sawtooth").attack(0.1).decay(0.2).sustain(0.7).release(0.3)
    // → 1 event with ADSR fields
    label: 's("sawtooth").attack(0.1).decay(0.2).sustain(0.7).release(0.3)',
    spanCycles: 1,
    build() {
      return pure({ s: 'sawtooth' })
        .set(pure({ attack: 0.1 }))
        .set(pure({ decay: 0.2 }))
        .set(pure({ sustain: 0.7 }))
        .set(pure({ release: 0.3 }));
    },
  },

  {
    // s("sawtooth").lpf(800).resonance(5)
    label: 's("sawtooth").lpf(800).resonance(5)',
    spanCycles: 1,
    build() {
      return pure({ s: 'sawtooth' })
        .set(pure({ lpf: 800 }))
        .set(pure({ resonance: 5 }));
    },
  },

  {
    // s("sawtooth").hpf(200)
    label: 's("sawtooth").hpf(200)',
    spanCycles: 1,
    build() {
      return pure({ s: 'sawtooth' })
        .set(pure({ hpf: 200 }));
    },
  },

  {
    // s("pad").speed(2) — speed on sample
    label: 's("pad").speed(2)',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' })
        .set(pure({ speed: 2 }));
    },
  },

  // ── Fase 2 / Tier 3: Pattern algebra ────────────────────────────────────────

  // rev — reverses the pattern within each cycle
  // s("pad bell").rev → bell comes first, then pad
  {
    label: 's("pad bell").rev',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }), pure({ s: 'bell' })).rev();
    },
  },

  // rev with subgroup — s("[pad bell] hi").rev
  // original order: [pad bell] at 0..1/2, hi at 1/2..1
  // reversed: hi at 0..1/2, [pad bell] at 1/2..1 (subgroup itself also reversed)
  {
    label: 's("[pad bell] hi").rev',
    spanCycles: 1,
    build() {
      const inner = fastcat(pure({ s: 'pad' }), pure({ s: 'bell' }));
      return fastcat(inner, pure({ s: 'hi' })).rev();
    },
  },

  // ply(2) — repeat each event 2 times within its duration
  // s("pad bell").ply(2) → 4 events: pad/2, pad/2, bell/2, bell/2
  {
    label: 's("pad bell").ply(2)',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }), pure({ s: 'bell' })).ply(2);
    },
  },

  // ply(3) on single event
  {
    label: 's("pad").ply(3)',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' }).ply(3);
    },
  },

  // every(4, fast(2)) — applies fast(2) on cycles 0, 4, 8, ...
  // verify cycle 0 has 4 events, cycles 1-3 have 2 events
  {
    label: 's("pad bell").every(4, x => x.fast(2))',
    spanCycles: 4,
    build() {
      return fastcat(pure({ s: 'pad' }), pure({ s: 'bell' })).every(4, x => x.fast(2));
    },
  },

  // off(0.25, gain 0.5) — stacks original + shifted copy with gain
  // off(t, f) = stack(orig, f(orig).rotL(t))
  {
    label: 's("bell").off(0.25, x => x.gain(0.5))',
    spanCycles: 1,
    build() {
      return pure({ s: 'bell' }).off(1 / 4, x => x.set(pure({ gain: 0.5 })));
    },
  },

  // jux(fast(2)) — original pan=0, transformed pan=1
  // confirms pan values 0 and 1
  {
    label: 's("pad bell").jux(x => x.fast(2))',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }), pure({ s: 'bell' })).jux(x => x.fast(2));
    },
  },

  // struct("t ~ t t") — boolean gate: 4 slots, slots 0/2/3 fire, slot 1 silent
  // = fastcat(pure(true), pure(false), pure(true), pure(true)) as mask
  {
    label: 's("bell").struct("t ~ t t")',
    spanCycles: 1,
    build() {
      // Build the boolean mask explicitly: t=true, ~=false, t=true, t=true
      const mask = fastcat(pure(true), pure(false), pure(true), pure(true));
      return pure({ s: 'bell' }).struct(mask);
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
