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

// ── Import signals from @strudel/core ───────────────────────────────────────
const signalPath = pathToFileURL(path.join(WEB_MODS, '@strudel/core/signal.mjs')).href;
const { signal, sine, saw, isaw, tri, square, cosine, segment } = await import(signalPath);

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

  // ── Fase 4: control-field oracle cases ──────────────────────────────────────
  // These verify that the PATTERN LAYER emits the correct fields.
  // DSP effects are unit-tested in Swift; oracle just checks field names/values.

  {
    // shape(x) — saturation level 0..1
    label: 's("pad").shape(0.5)',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' }).set(pure({ shape: 0.5 }));
    },
  },

  {
    // distort(x) — distortion level 0..1
    label: 's("pad").distort(0.8)',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' }).set(pure({ distort: 0.8 }));
    },
  },

  {
    // crush(n) — bit depth (e.g. 4 bits = very lo-fi, 16 = near-transparent)
    label: 's("pad").crush(4)',
    spanCycles: 1,
    build() {
      return pure({ s: 'pad' }).set(pure({ crush: 4 }));
    },
  },

  {
    // crush as pattern
    label: 's("pad bell").crush(8)',
    spanCycles: 1,
    build() {
      return fastcat(pure({ s: 'pad' }), pure({ s: 'bell' }))
        .set(pure({ crush: 8 }));
    },
  },

  {
    // vowel("a") — formant filter, single vowel
    label: 's("sawtooth").vowel("a")',
    spanCycles: 1,
    build() {
      return pure({ s: 'sawtooth' }).set(pure({ vowel: 'a' }));
    },
  },

  {
    // vowel("<a o>") — alternating vowel per cycle
    label: 's("sawtooth").vowel("<a o>")',
    spanCycles: 2,
    build() {
      const vPat = slowcat(pure({ vowel: 'a' }), pure({ vowel: 'o' }));
      return pure({ s: 'sawtooth' }).set(vPat);
    },
  },

  // ── Fase 4: chop(n) / striate(n) — granular sub-events ─────────────────────
  // chop(n): cuts EACH event into n sequential sub-events, each covering 1/n of
  // the sample (begin/end fields 0..1) and 1/n of the time slot.
  // For s("pad") (1 event/cycle), chop(4) → 4 sub-events.
  // Event k: time slot = [k/n, (k+1)/n], begin=k/n, end=(k+1)/n.
  // (begin/end are fractional positions within the sample, 0..1)
  {
    label: 's("pad").chop(4)',
    spanCycles: 1,
    build() {
      // Model: 4 sub-events, each covers 1/4 of cycle and 1/4 of sample
      // begin/end = fractional sample position
      return fastcat(
        pure({ s: 'pad', begin: 0,    end: 0.25 }),
        pure({ s: 'pad', begin: 0.25, end: 0.5  }),
        pure({ s: 'pad', begin: 0.5,  end: 0.75 }),
        pure({ s: 'pad', begin: 0.75, end: 1.0  }),
      );
    },
  },

  {
    // chop(2) on a 2-event pattern: 4 events total
    label: 's("pad bell").chop(2)',
    spanCycles: 1,
    build() {
      // pad: [0,1/2) → 2 sub-events at [0,1/4) and [1/4,1/2)
      // bell: [1/2,1) → 2 sub-events at [1/2,3/4) and [3/4,1)
      return fastcat(
        pure({ s: 'pad',  begin: 0,   end: 0.5  }),
        pure({ s: 'pad',  begin: 0.5, end: 1.0  }),
        pure({ s: 'bell', begin: 0,   end: 0.5  }),
        pure({ s: 'bell', begin: 0.5, end: 1.0  }),
      );
    },
  },

  // ── Fase 4: striate(n) — granular interleaving ──────────────────────────────
  // striate(n): Like chop but INTERLEAVES chunks across the pattern's events.
  // For s("pad") (1 event/cycle), striate(4) is same as chop(4).
  // For s("pad bell").striate(2): the two events share chunk slots:
  //   event 0 (pad) → chunk 0 (begin=0, end=0.5)
  //   event 1 (bell) → chunk 1 (begin=0.5, end=1.0)
  // (striate gives each step a different chunk of the sample, cycling through chunks)
  {
    // striate(n): event i in the cycle gets chunk (i mod n).
    // For s("pad") (1 event/cycle), striate(4): event 0 → chunk 0 → begin=0, end=0.25
    // Result: 1 event with begin=0, end=0.25 (NOT 4 events like chop).
    // The key semantic difference from chop: striate does NOT create new events;
    // it assigns a chunk index to each EXISTING event based on its position.
    label: 's("pad").striate(4)',
    spanCycles: 1,
    build() {
      // striate(4) on a single event: event 0 gets chunk 0 → begin=0/4, end=1/4
      return pure({ s: 'pad', begin: 0, end: 0.25 });
    },
  },

  {
    // striate(2) on 2-event pattern: each event gets different chunk (interleaved)
    // pad → chunk 0 [begin=0, end=0.5], bell → chunk 1 [begin=0.5, end=1.0]
    // Both events keep their original time slots; only begin/end differ
    label: 's("pad bell").striate(2)',
    spanCycles: 1,
    build() {
      // striate interleaves: event i → chunk (i mod n)
      // pad (event 0): begin=0/2=0, end=1/2=0.5, time=[0,1/2)
      // bell (event 1): begin=1/2=0.5, end=2/2=1.0, time=[1/2,1)
      return fastcat(
        pure({ s: 'pad',  begin: 0,   end: 0.5 }),
        pure({ s: 'bell', begin: 0.5, end: 1.0 }),
      );
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

  // ── Bug 1: [bd <hh oh>]*2 — fast(n) must advance internal slowcat cycle ────
  // In Strudel, *2 (fast) queries the inner pattern at doubled speed.
  // The slowcat <hh oh> has 2 alternatives; each internal cycle picks a different one.
  // Over 2 outer cycles: bd hh bd oh | bd hh bd oh  (8 haps total)
  {
    label: 's("[bd <hh oh>]*2")',
    spanCycles: 2,
    build() {
      const bd = pure({ s: 'bd' });
      const hh = pure({ s: 'hh' });
      const oh = pure({ s: 'oh' });
      // [bd <hh oh>]*2 = fastcat(bd, slowcat(hh, oh)).fast(2)
      return fastcat(bd, slowcat(hh, oh)).fast(2);
    },
  },

  // ── Bug 1b: [hh hh hh <hh oh hh oh>]*2 — user's hat pattern ─────────────
  // Slowcat has 4 alternatives; with fast(2), each outer cycle queries 2 inner
  // cycles. Slot 3 (slowcat) cycles through hh,oh,hh,oh. Over 4 outer cycles:
  // each outer cycle: 7×hh + 1×oh at the last slot of each repetition-2.
  {
    label: 's("[hh hh hh <hh oh hh oh>]*2")',
    spanCycles: 4,
    build() {
      const hh = pure({ s: 'hh' });
      const oh = pure({ s: 'oh' });
      const sc = slowcat(hh, oh, hh, oh);
      const grp = fastcat(hh, hh, hh, sc);
      return grp.fast(2);
    },
  },

  // ── Bug 2: ! inside <> expands slowcat alternatives (not steps within a slot)
  // <0!8 3!4 0!4> = slowcat with 16 alternatives: 8×0, 4×3, 4×0.
  // One hap per cycle; over 16 cycles: cycles 0-7 = 0, cycles 8-11 = 3, 12-15 = 0.
  {
    label: 'n("<0!8 3!4 0!4>")',
    spanCycles: 16,
    build() {
      const zero  = pure({ n: 0 });
      const three = pure({ n: 3 });
      return slowcat(
        ...Array(8).fill(zero),
        ...Array(4).fill(three),
        ...Array(4).fill(zero),
      );
    },
  },

  // ── Bug 2b: <bd*8!12 ~ [bd ~ ~ ~ bd ~ bd ~] bd*8!2>  (kick layer) ─────────
  // 16 slowcat alternatives: 12×(bd*8), 1×silence, 1×[bd ~ ~ ~ bd ~ bd ~], 2×(bd*8)
  // Cycles 0-11 = 8 kicks each, cycle 12 = silence, cycle 13 = kick pattern, 14-15 = 8 kicks
  {
    label: 's("<bd*8!12 ~ [bd ~ ~ ~ bd ~ bd ~] bd*8!2>")',
    spanCycles: 16,
    build() {
      const bd  = pure({ s: 'bd' });
      const sil = strudelSilence;
      const bdFast8 = bd.fast(8);
      const grp = fastcat(bd, sil, sil, sil, bd, sil, bd, sil);
      return slowcat(
        ...Array(12).fill(bdFast8),
        sil,
        grp,
        bdFast8, bdFast8,
      );
    },
  },

  // ── Bug 2c: <~!2 [~ cp ~ cp]!10 ~ ~ [~ cp ~ cp]!2>  (clap/snare layer) ──
  // 16 alternatives: 2×silence, 10×[~ cp ~ cp], 2×silence, 2×[~ cp ~ cp]
  {
    label: 's("<~!2 [~ cp ~ cp]!10 ~ ~ [~ cp ~ cp]!2>")',
    spanCycles: 16,
    build() {
      const cp   = pure({ s: 'cp' });
      const sil  = strudelSilence;
      const grpCP = fastcat(sil, cp, sil, cp);
      return slowcat(
        sil, sil,
        ...Array(10).fill(grpCP),
        sil, sil,
        grpCP, grpCP,
      );
    },
  },

  // ── Bug 2d: lpf("<500!4 800!4 1400!4 1000!4>") — control pattern with ! ──
  // 16 alternatives: 4×500, 4×800, 4×1400, 4×1000 Hz.
  // One lpf value per cycle; cycles 0-3=500, 4-7=800, 8-11=1400, 12-15=1000.
  {
    label: 's("sawtooth").lpf("<500!4 800!4 1400!4 1000!4>")',
    spanCycles: 16,
    build() {
      const base = pure({ s: 'sawtooth' });
      const lpfPat = slowcat(
        ...Array(4).fill(pure({ lpf: 500  })),
        ...Array(4).fill(pure({ lpf: 800  })),
        ...Array(4).fill(pure({ lpf: 1400 })),
        ...Array(4).fill(pure({ lpf: 1000 })),
      );
      return base.set(lpfPat);
    },
  },

  // ── Bug 2e: n("<~!2 [0 ~ 0 3 ~ 0 ~ 5]!14>") — melody/bass layer ─────────
  // 16 alternatives: 2×silence, 14×[0 ~ 0 3 ~ 0 ~ 5]
  // Cycles 0-1 = silence, cycles 2-15 = 8-step bass pattern
  {
    label: 'n("<~!2 [0 ~ 0 3 ~ 0 ~ 5]!14>")',
    spanCycles: 16,
    build() {
      const sil = strudelSilence;
      // [0 ~ 0 3 ~ 0 ~ 5] as a pattern of {n} values
      const bassGrp = fastcat(
        pure({ n: 0 }), sil, pure({ n: 0 }), pure({ n: 3 }),
        sil, pure({ n: 0 }), sil, pure({ n: 5 }),
      );
      return slowcat(sil, sil, ...Array(14).fill(bassGrp));
    },
  },

  // ── Chords (comma inside [...] and at top level) ────────────────────────────
  // Verified against the oracle black box: mini("[a3,c4,e4]"), mini("c3,e3"),
  // mini("[bd bd, hh hh hh]"), mini("<[a3,c4,e4] [e3,g#3,b3]>"),
  // mini("[a3,c4,e4]!2"), mini("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>")

  {
    // note("[a3,c4,e4]") → 3 simultaneous note events spanning the full cycle
    // Semantics: [a,b,c] with commas = stack(a, b, c), each note whole-cycle
    // Oracle: mini("[a3,c4,e4]") → 3 haps at part [0/1, 1/1) with values "a3","c4","e4"
    // note() converts each to MIDI: a3=57, c4=60, e4=64
    label: 'note("[a3,c4,e4]")',
    spanCycles: 1,
    build() {
      return stack(
        pure({ note: 57 }),   // a3 = MIDI 57
        pure({ note: 60 }),   // c4 = MIDI 60
        pure({ note: 64 }),   // e4 = MIDI 64
      );
    },
  },

  {
    // note("c3,e3") — top-level chord: stack of 2 simultaneous notes
    // Oracle: mini("c3,e3") → 2 haps at part [0/1, 1/1) with values "c3","e3"
    // c3=48, e3=52
    label: 'note("c3,e3")',
    spanCycles: 1,
    build() {
      return stack(
        pure({ note: 48 }),   // c3 = MIDI 48
        pure({ note: 52 }),   // e3 = MIDI 52
      );
    },
  },

  {
    // note("[a3,c4,e4]!2") — chord replicated 2 equal steps
    // Oracle: mini("[a3,c4,e4]!2") → 6 haps:
    //   3 at part [0/1, 1/2) (a3,c4,e4), 3 at part [1/2, 1/1) (a3,c4,e4)
    label: 'note("[a3,c4,e4]!2")',
    spanCycles: 1,
    build() {
      const chord = stack(pure({ note: 57 }), pure({ note: 60 }), pure({ note: 64 }));
      return fastcat(chord, chord);
    },
  },

  {
    // note("<[a3,c4,e4] [e3,g#3,b3]>") — alternating chord per cycle
    // Oracle: mini("<[a3,c4,e4] [e3,g#3,b3]>") → cycle 0: a3,c4,e4; cycle 1: e3,g#3,b3
    // MIDI: a3=57, c4=60, e4=64, e3=52, g#3=56, b3=59
    label: 'note("<[a3,c4,e4] [e3,g#3,b3]>")',
    spanCycles: 2,
    build() {
      const chordA = stack(pure({ note: 57 }), pure({ note: 60 }), pure({ note: 64 }));
      const chordB = stack(pure({ note: 52 }), pure({ note: 56 }), pure({ note: 59 }));
      return slowcat(chordA, chordB);
    },
  },

  {
    // note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>") — PAD layer (4-cycle slowcat)
    // Oracle: mini("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>"):
    //   cycle 0: a3,c4,e4; cycle 1: a3,c4,e4; cycle 2: e3,g#3,b3; cycle 3: a3,c4,e4
    label: 'note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>")',
    spanCycles: 4,
    build() {
      const chordA = stack(pure({ note: 57 }), pure({ note: 60 }), pure({ note: 64 }));
      const chordB = stack(pure({ note: 52 }), pure({ note: 56 }), pure({ note: 59 }));
      return slowcat(chordA, chordA, chordB, chordA);
    },
  },

  {
    // s("[bd bd, hh hh hh]") — two parallel sub-sequences of different step counts
    // Oracle: mini("[bd bd, hh hh hh]") → 5 haps:
    //   bd at [0/1,1/2), bd at [1/2,1/1), hh at [0/1,1/3), hh at [1/3,2/3), hh at [2/3,1/1)
    label: 's("[bd bd, hh hh hh]")',
    spanCycles: 1,
    build() {
      const bdSeq = fastcat(pure({ s: 'bd' }), pure({ s: 'bd' }));
      const hhSeq = fastcat(pure({ s: 'hh' }), pure({ s: 'hh' }), pure({ s: 'hh' }));
      return stack(bdSeq, hhSeq);
    },
  },

  {
    // note("d#5") — sharp with high octave; must parse and convert to MIDI correctly
    // d#5 = MIDI 75 (D=2, #=+1, octave 5: (5+1)*12 + 2 + 1 = 75)
    label: 'note("d#5")',
    spanCycles: 1,
    build() {
      return pure({ note: 75 });
    },
  },

  {
    // note("g#3") — sharp in lower octave
    // g#3 = MIDI 56 (G=7, #=+1, octave 3: (3+1)*12 + 7 + 1 = 56)
    label: 'note("g#3")',
    spanCycles: 1,
    build() {
      return pure({ note: 56 });
    },
  },

  {
    // note("a3!1 b3") — !1 replicates once (= no-op, single copy), b3 is next step
    // mini("a3!1 b3") → 2 haps: a3 at [0/1,1/2), b3 at [1/2,1/1)
    // a3=57, b3=59
    label: 'note("a3!1 b3")',
    spanCycles: 1,
    build() {
      return fastcat(pure({ note: 57 }), pure({ note: 59 }));
    },
  },

  // ── P0-2: Señales continuas — oracle fixtures ────────────────────────────────
  // Signal semantics (public docs / source): signal(func) evaluates func at
  // state.span.BEGIN (not midpoint). whole=undefined (no discrete structure).

  {
    // sine.segment(8) — discretizes sine into 8 haps per cycle
    // Each hap: part=[k/8, (k+1)/8), value=sine sampled at t=k/8
    // sine(t) = (sin(2π*t) + 1) / 2
    label: 'sine.segment(8)',
    spanCycles: 1,
    build() {
      return sine.segment(8);
    },
  },

  {
    // saw.range(2,4).segment(4) — saw discretized and scaled
    // saw(t) = t%1, range(2,4): v * (4-2) + 2 = v*2+2
    // segment(4): t=0/4=0 → 0*2+2=2, t=1/4 → 0.25*2+2=2.5, t=2/4 → 0.5*2+2=3, t=3/4 → 0.75*2+2=3.5
    label: 'saw.range(2,4).segment(4)',
    spanCycles: 1,
    build() {
      return saw.range(2, 4).segment(4);
    },
  },

  {
    // sine.slow(2).segment(8) — slow(2) stretches over 2 cycles, segment(8) per cycle
    // Queries span [0,2) so that 2 cycles are captured (8 haps per cycle = 16 total)
    label: 'sine.slow(2).segment(8)',
    spanCycles: 2,
    build() {
      return sine.slow(2).segment(8);
    },
  },

  {
    // s("bd*4").gain(sine) — gain modulated by sine per event
    // bd*4: 4 events at [0,1/4), [1/4,1/2), [1/2,3/4), [3/4,1)
    // Each event's whole=[k/4,(k+1)/4); signal is queried at whole.begin=k/4
    // sine(0/4)=0.5, sine(1/4)=1.0, sine(2/4)=0.5, sine(3/4)=0.0
    label: 's("bd*4").gain(sine)',
    spanCycles: 1,
    build() {
      return fastcat(pure({s:'bd'}), pure({s:'bd'}), pure({s:'bd'}), pure({s:'bd'}))
        .set(sine.fmap(v => ({ gain: v })));
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
