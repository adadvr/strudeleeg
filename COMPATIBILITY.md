# MiniEngine — Compatibility with Strudel

Living document: function → status → equivalence notes.

| Function | Status | Notes |
|---|---|---|
| `s("...")` | ✅ nativo | Mini-notation string. Supports sequence, groups `[]`, slowcat `<>`, silence `~`, `*`, `!`, `@` |
| `note("...")` | ✅ nativo | Note names (c4, e4#, bb3) → MIDI. Mini-notation fully supported |
| `n("...")` | ✅ nativo | Scale degree indices. Used with `.scale()` |
| `scale("Root:name")` | ✅ nativo | Maps n indices → MIDI. Supported scales: major, minor, dorian, mixolydian, pentatonic. Root: C–B with optional # (C#, Db, etc). Base octave: C3 = MIDI 48 (verified against oracle: n(0).scale("C:minor") = 48) |
| `.slow(n)` | ✅ nativo | Stretch time by n |
| `.fast(n)` | ✅ nativo | Compress time by n |
| `.gain(n\|"mini")` | ✅ nativo | Amplitude 0..1, patroneable |
| `.room(n)` | ✅ nativo | Reverb wet mix 0..1. Per-chain (AVAudioUnitReverb). mediumHall preset |
| `.cutoff(n)` | ✅ nativo | Low-pass filter frequency (Hz). Per-chain (AVAudioUnitEQ) |
| `.pan(n\|"mini")` | ✅ nativo (Fase 1) | Stereo position 0..1 (0=left, 0.5=center, 1=right). Mapped to AVAudioMixerNode.pan -1..1 per event |
| `.delay(n)` | ✅ nativo (Fase 1) | Echo wet mix 0..1. Maps to AVAudioUnitDelay wetDryMix (n×100) |
| `.delaytime(s)` | ✅ nativo (Fase 1) | Echo delay time in seconds. Default: 0.25s if `.delay()` used without explicit delaytime |
| `.delayfeedback(n)` | ✅ nativo (Fase 1) | Echo feedback 0..1. Default: 0.5 if `.delay()` used without explicit feedback. AVAudioUnitDelay.feedback = f×100 |
| `.euclid(k,n)` | ✅ nativo (Fase 1) | Euclidean rhythm via Bjorklund algorithm. k onsets in n steps |
| `.euclid(k,n,rot)` | ✅ nativo (Fase 1) | With rotation: shifts onset positions forward by rot steps (right-rotation of boolean array) |
| `setcps(x)` | ✅ nativo (Fase 1) | Set cycles-per-second. Default: 0.5 (1 cycle = 2s). As top-level statement before pattern |
| `setcpm(x)` | ✅ nativo (Fase 1) | Set cycles-per-minute. Equivalent to setcps(x/60) |
| `stack(...)` | ✅ nativo | Stack multiple layers (all fire simultaneously) |
| `// comments` | ✅ nativo | Line comments stripped before parsing |
| Mini `[...]` groups | ✅ nativo | Subdivide a step into equal sub-steps |
| Mini `<...>` slowcat | ✅ nativo | One alternative per cycle, rotating |
| Mini `~` silence | ✅ nativo | Silent step in sequence |
| Mini `a*n` fast | ✅ nativo (Fase 1) | Step plays n times faster within its slot |
| Mini `a!n` replicate | ✅ nativo (Fase 1) | Expand to n equal copies of the step. Default n=2 if no number |
| Mini `a@w` weight | ✅ nativo (Fase 1) | Step occupies w weight-units relative to others (e.g. `a@3 b` → a=3/4, b=1/4) |
| `rev` | ✅ nativo (Fase 2) | Reverses events within each cycle. `s("pad bell").rev` → bell, pad. Oracle verified including subgroups `[]` |
| `ply(n)` | ✅ nativo (Fase 2) | Repeats each event n times within its structural duration (rolls). `s("pad bell").ply(2)` → 4 events. Oracle verified |
| `every(n, f)` | ✅ nativo (Fase 2) | Applies f on cycles 0, n, 2n, … (cycle 0 of each block of n). Confirmed with oracle: `every(4, fast(2))` → cycles 0,4,8 get 4 events; 1,2,3 get 2. Lambda parser supports `x => x.method(args)` chaining |
| `sometimes(f)` | ✅ nativo (Fase 2) | Applies f with probability 0.5. **RNG: deterministic PRNG (xorshift64, seeded by cycle+eventIndex)**. Statistical equivalence only — Strudel's internal RNG is time-based and not reproducible clean-room. See note below |
| `often(f)` | ✅ nativo (Fase 2) | Applies f with probability 0.75. Same RNG note |
| `rarely(f)` | ✅ nativo (Fase 2) | Applies f with probability 0.25. Same RNG note |
| `off(t, f)` | ✅ nativo (Fase 2) | Stacks original + f(copy) shifted RIGHT by t cycles. `off(t,f) = stack(self, f(self).rotR(t))`. Oracle confirmed: pan=0, copy's whole at t offset |
| `jux(f)` | ✅ nativo (Fase 2) | Original at pan=0 (left), f(copy) at pan=1 (right). Oracle confirmed pan values are exactly 0 and 1 |
| `struct("...")` | ✅ nativo (Fase 2) | Boolean gate: fires events at positions where mask is true. Supports `t`/`true` and `~`/`f`/`false`. Oracle verified |
| `sound(...)` / `s("sawtooth"\|"square"\|"sine"\|"triangle")` | ✅ nativo (Fase 3) | Oscillator synths. `sound` is alias of `s`. Synth events detected via `"synth"` field in control map. AVAudioSourceNode with voice pool (8 voices). polyBLEP band-limited saw/square; triangle via leaky integrator; sine trivial. |
| `attack(s)` | ✅ nativo (Fase 3) | ADSR attack in seconds. Default: 0.001s (Strudel docs). Patroneable |
| `decay(s)` | ✅ nativo (Fase 3) | ADSR decay in seconds. Default: 0.05s. Patroneable |
| `sustain(0..1)` | ✅ nativo (Fase 3) | ADSR sustain level 0..1. Default: 0.6. Patroneable |
| `release(s)` | ✅ nativo (Fase 3) | ADSR release in seconds. Default: 0.1s (Strudel docs). Patroneable |
| `lpf(hz)` | ✅ nativo (Fase 3) | Low-pass filter frequency (Hz). Alias for `cutoff` on synth chain. AVAudioUnitEQ band[0] lowPass. Patroneable |
| `hpf(hz)` | ✅ nativo (Fase 3) | High-pass filter frequency (Hz). AVAudioUnitEQ band[1] highPass. Patroneable |
| `resonance(q)` | ✅ nativo (Fase 3) | Filter Q (0..50 per Strudel docs). Mapped to AVAudioUnitEQ bandwidth in octaves: `bandwidth = clamp(2.0/max(0.01,Q), 0.05, 5.0)`. Applies to both lpf and hpf bands. See resonance mapping note below |
| `speed(x)` | ✅ nativo (Fase 3) | Sample playback speed (1=normal, 2=double speed +1 octave, 0.5=half). Multiplied with note-based varispeed rate. Negative speed: not supported (documented). For synths: speed() applies to pattern level only (frequency computed from MIDI directly). Patroneable |
| `shape` / `distort` | ❌ no | Saturation (Fase 4) |
| `chop` / `striate` | ❌ no | Granular (Fase 4) |
| `crush` | ❌ no | Bitcrusher (Fase 4) |
| `vowel` | ❌ no | Formant filter (Fase 4) |

## Nota sobre equivalencia estadística del RNG (sometimes/often/rarely)

Strudel usa una señal `rand` basada en tiempo (no determinista desde el exterior) para decidir qué eventos transformar en `sometimes`/`often`/`rarely`. No es accesible de forma clean-room.

El MiniEngine implementa un PRNG puro (xorshift64 + splitmix64) sembrado por `(ciclo, índice_evento)`:
- **Determinismo garantizado**: mismo seed → misma secuencia siempre (crucial para reproducibilidad y tests estables).
- **Equivalencia estadística**: la proporción de aplicación converge a la probabilidad especificada (0.5, 0.75, 0.25) en muchos ciclos.
- **No equivalente bit a bit**: la decisión concreta por evento difiere de Strudel (distintas semillas/algoritmos). Esto es correcto para producción clean-room y para el EEG (donde queremos seed controlada, no aleatoriedad del motor web).

## Defaults (documented)

| Parameter | Default | Notes |
|---|---|---|
| `cps` | 0.5 | 1 cycle = 2 seconds |
| `delay` wet | 0 (dry) | No echo unless `.delay(x)` called |
| `delaytime` | 0.25s | Used when `.delay()` called without explicit delaytime |
| `delayfeedback` | 0.5 (50%) | Used when `.delay()` called without explicit delayfeedback |
| `pan` | 0 (center) | No pan node applied unless `.pan()` called |
| Scale base octave | C3 = MIDI 48 | `n(0).scale("C:minor")` = 48 (verified with Strudel oracle) |
| `attack` | 0.001s | Per Strudel public docs (strudel.cc/learn/effects) |
| `decay` | 0.05s | Per Strudel public docs |
| `sustain` | 0.6 | Per Strudel public docs (0..1) |
| `release` | 0.1s | Per Strudel public docs |
| Synth default note | MIDI 48 (C3) | When no `note()` provided: C3 = 130.81 Hz. Same root as scale system. |
| `speed` | 1.0 | No speed change. Applied multiplicatively with note-based varispeed rate |

## Scale reference

Supported scale names (case-insensitive):

| Name | Intervals |
|---|---|
| `major` | 0 2 4 5 7 9 11 |
| `minor` | 0 2 3 5 7 8 10 (natural minor / aeolian) |
| `dorian` | 0 2 3 5 7 9 10 |
| `mixolydian` | 0 2 4 5 7 9 10 |
| `pentatonic` | 0 2 4 7 9 |

Format: `"Root:name"` where Root = C, C#, Db, D, D#, Eb, E, F, F#, Gb, G, G#, Ab, A, A#, Bb, B.

## Audio chain (per sample layer)

```
AVAudioPlayerNode → AVAudioUnitVarispeed → AVAudioUnitEQ (lowpass)
  → AVAudioUnitReverb (room) → AVAudioUnitDelay (delay)
  → AVAudioMixerNode (pan) → mainMixer
```

`delay` node is always in chain but wet=0 (dry) unless `.delay()` called.
`pan` node always in chain at center (0) unless `.pan()` called.

## Audio chain (per synth layer — Fase 3)

```
AVAudioSourceNode (voice pool, 8 voices)
  → AVAudioUnitEQ (band[0]=lowPass lpf, band[1]=highPass hpf)
  → AVAudioUnitReverb (room)
  → AVAudioUnitDelay (delay)
  → AVAudioMixerNode (pan)
  → mainMixer
```

- Polyphony: 8-voice pool per synth type. Voice steal: LRU (oldest birth).
- Both EQ bands are bypassed by default; activated when lpf/hpf called.
- ADSR envelope is computed per-voice in the render block (no Apple AU needed for envelope).

## Resonance mapping note (Fase 3)

`resonance` in Strudel is a filter Q parameter (range 0..50 per public docs).
AVAudioUnitEQ uses bandwidth in octaves (not Q directly).

Mapping used: `bandwidth = clamp(2.0 / max(0.01, Q), 0.05, 5.0)`

| Q | bandwidth (octaves) | Character |
|---|---|---|
| 0 | 5.0 | Wide, no resonance |
| 1 | 2.0 | Gentle |
| 5 | 0.4 | Moderate resonance |
| 10 | 0.2 | Strong |
| 50 | 0.05 | Very sharp (minimum bandwidth) |

This is a practical approximation; exact Q-to-bandwidth conversion depends on AVAudioUnitEQ's internal implementation (Apple private). Documented compromise.

## Synth oscillators (Fase 3)

All oscillators are band-limited using polyBLEP corrections (standard public-domain DSP technique).

| Waveform | Method | Note |
|---|---|---|
| `sine` | sin(2π·phase) | Trivial, alias-free |
| `sawtooth` | naive saw + polyBLEP at phase=0 | Suppresses aliasing at discontinuity |
| `square` | naive square + polyBLEP at 0 and 0.5 | Suppresses aliasing at both transitions |
| `triangle` | leaky integrator of polyBLEP square (leak=0.999) | Scaled by 4×dt; DC stable |

## What is NOT supported (Fase 3)

| Feature | Status | Notes |
|---|---|---|
| Negative `speed()` (reverse) | Not supported | Documented. `scheduleSegment` reverse is complex to implement correctly for arbitrary buffers. Document for Fase 4 if needed. |
| `speed()` affecting synth frequency | Not applicable | Synth frequency is computed from MIDI note; speed() is pattern-level only for synths |
| Per-event room/cutoff/lpf/hpf/resonance | Per-chain compromise | Same as Fase 1. Node-global parameters updated at dispatch time — events alternating filter values in the same layer share the last-set value |
| Offline filter audio test | Not tested | AVAudioUnitEQ requires a running engine. Parameter mapping is unit-tested. Actual DSP filter roll-off trusted to Apple |
