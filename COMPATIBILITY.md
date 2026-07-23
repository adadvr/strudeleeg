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
| `lpf(hz)` | ✅ nativo (Fase 3 → P0-3) | Low-pass filter frequency (Hz). **Synths: per-voice biquad LPF** (Audio EQ Cookbook direct-form II transposed, 2nd-order Butterworth Q=0.707, 64-sample onset ramp). **Samples: per-event buffer preprocessing** (biquad applied to PCM copy). Two simultaneous voices can have different lpf. AVAudioUnitEQ kept in graph but permanently bypassed. Patroneable |
| `hpf(hz)` | ✅ nativo (Fase 3 → P0-3) | High-pass filter frequency (Hz). **Synths: per-voice biquad HPF** (same formulas, HPF variant). **Samples: per-event buffer preprocessing**. Patroneable |
| `resonance(q)` | ✅ nativo (Fase 3 → P0-3) | Filter Q (0..50 per Strudel docs). Applied to per-voice biquad (synths) and per-event buffer biquad (samples). Default Q=0.707 (Butterworth — maximally flat). Range clamped to [0.01, 50]. |
| `speed(x)` | ✅ nativo (Fase 3) | Sample playback speed (1=normal, 2=double speed +1 octave, 0.5=half). Multiplied with note-based varispeed rate. Negative speed: not supported (documented). For synths: speed() applies to pattern level only (frequency computed from MIDI directly). Patroneable |
| `shape(x)` | ✅ nativo (Fase 4) | Soft saturation 0..1. AVAudioUnitDistortion, preset `.multiDistortedFunk` (warm overdrive). x → wetDryMix (x×100). Per-chain compromise. Patroneable |
| `distort(x)` | ✅ nativo (Fase 4) | Same DSP path as shape (same preset). Strudel uses different curves; here both use the same preset but are separate controllable parameters. Documented approximation |
| `crush(n)` | ✅ nativo (Fase 4) | Bitcrusher. n = effective bit depth (1..16). Formula: `round(s × 2^(n-1)) / 2^(n-1)` (public domain). Samples: buffer pre-processed per event. Synths: applied in render block per voice. Patroneable |
| `vowel("a"\|"e"\|"i"\|"o"\|"u")` | ✅ nativo (Fase 4) | Formant filter. AVAudioUnitEQ with 3 parametric bands (F1/F2/F3). Frequencies from Peterson & Barney (1952) acoustic tables. Patroneable: `vowel("<a o>")` alternates per cycle |
| `chop(n)` | ✅ nativo (Fase 4) | Cuts each event into n sequential sub-events. Each sub-event: time = 1/n of original, begin/end = k/n..(k+1)/n (sample fraction). Oracle verified. Scheduler plays each segment via sub-buffer |
| `striate(n)` | ✅ nativo (Fase 4) | Assigns chunk (i mod n) to event i. Does NOT create new events (different from chop). Event i → begin=i%n/n, end=(i%n+1)/n. Oracle verified: `s("pad").striate(4)` → 1 event (chunk 0); `s("pad bell").striate(2)` → 2 events with interleaved chunks |
| `chorus` | ❌ no (Fase 4) | Not implemented. See note below |
| `phaser` | ❌ no (Fase 4) | Not implemented. See note below |
| `bank("name")` | ✅ nativo (Fase 5) | Sample bank selection. `s("bd").bank("tr909")` → looks up key "tr909_bd". Patroneable. Scheduler: if bank field present, effective lookup key = `"\(bank)_\(s)"`. Unknown bank → friendly log warning, no crash. Both engines use the same key convention. |
| `dec(x)` | ✅ nativo (Fase 5) | Alias for `decay(x)`. Strudel short form. Supports leading-dot literals: `.dec(.4)` = `.dec(0.4)`. |
| `signal { t in ... }` | ✅ nativo (P0-2) | Swift-only EEG hook. Creates a continuous Pattern<Double> sampled at span.begin. whole=nil (no discrete structure). Not available in the code editor. |
| `sine` | ✅ nativo (P0-2) | Sine signal 0..1. sine(t) = (sin(2πt)+1)/2. Phase: t=0→0.5, t=0.25→1.0 (peak), t=0.5→0.5, t=0.75→0.0 (trough). Exact match with oracle. |
| `saw` | ✅ nativo (P0-2) | Sawtooth 0..1. saw(t) = t mod 1. Rises from 0, wraps at cycle. Exact match with oracle. |
| `isaw` | ✅ nativo (P0-2) | Inverse sawtooth 1..0. isaw(t) = 1 − (t mod 1). Exact match with oracle. |
| `tri` | ✅ nativo (P0-2) | Triangle 0..1. Implemented as fastcat(saw, isaw): rises 0→1 in first half, falls 1→0 in second. Exact match with oracle. |
| `square` | ✅ nativo (P0-2) | Square 0..1. square(t) = floor((t×2) mod 2). Low first half, high second half. Exact match with oracle. |
| `cosine` | ✅ nativo (P0-2) | Cosine 0..1. cosine(t) = (cos(2πt)+1)/2. Phase: t=0→1.0, t=0.25→0.5, t=0.5→0.0. Exact match with oracle. |
| `rand` | ✅ nativo (P0-2) | Pseudo-random signal [0,1). Deterministic: same t → same value. **APPROXIMATION**: sequence differs from Strudel (different hash — see rand note below). Distribution is uniform [0,1). |
| `perlin` | ✅ nativo (P0-2) | Smooth noise [0,1). Cubic Hermite interpolation between rand values at integer boundaries. **APPROXIMATION**: different hash than Strudel. Shape is smooth and bounded; exact values differ. |
| `.range(min, max)` | ✅ nativo (P0-2) | Scale 0..1 signal to [min, max]. Confirmed: saw.range(2,4).segment(4) → [2, 2.5, 3, 3.5]. |
| `.rangex(min, max)` | ✅ nativo (P0-2) | Exponential scale 0..1 → [min, max]. Useful for frequency parameters. min/max must be > 0. |
| `.segment(n)` | ✅ nativo (P0-2) | Discretize a signal into n haps/cycle. Each hap k: part=whole=[k/n,(k+1)/n), value=signal at t=k/n. Oracle confirmed: sine.segment(8)[0]=0.5, sine.segment(8)[2]=1.0. |
| Signal in control methods | ✅ nativo (P0-2) | `.gain(Pattern<Double>)`, `.lpf(Pattern<Double>)`, `.hpf(Pattern<Double>)`, `.pan(Pattern<Double>)`, `.room(Pattern<Double>)`, `.cutoff(Pattern<Double>)`, `.resonance(Pattern<Double>)`, `.speed(Pattern<Double>)` all accept a signal. Value evaluated at event whole.begin (appLeft semantics). |
| Signal in CodeParser | ✅ nativo (P0-2) | Expressions: `sine`, `saw`, `isaw`, `tri`, `square`, `cosine`, `rand`, `perlin` + chain `.range(a,b)`, `.rangex(a,b)`, `.slow(n)`, `.fast(n)`, `.segment(n)` parsed as argument to control methods. Examples: `.lpf(sine.range(200, 2000))`, `.gain(saw.slow(4))`, `.gain(rand.range(0,1))`. |
| `att(x)` | ✅ nativo (Fase 5) | Alias for `attack(x)`. |
| `sus(x)` | ✅ nativo (Fase 5) | Alias for `sustain(x)`. |
| `rel(x)` | ✅ nativo (Fase 5) | Alias for `release(x)`. |
| ADSR on samples | ✅ nativo (Fase 5) | ADSR envelope applied to sample PCM buffers when any of attack/decay/sustain/release is explicitly set. Pre-processed per event (same pattern as crush). If no ADSR param is set → buffer unchanged (backward-compat). |
| `orbit(n)` | ✅ nativo (P0-4) | Route layer to a named effect bus (integer ≥ 1). Default: orbit=1. Each orbit has its own AVAudioMixerNode (gain/duck prep) → AVAudioUnitReverb → AVAudioUnitDelay → mainMixer. Multiple layers on the same orbit share the reverb tail (same as Strudel). room/delay params updated from last event on that orbit (see orbit bus compromise below). Patternable. |
| `$:` | ✅ nativo (Fase 5) | Top-level parallel patterns. Each line starting with `$:` defines one pattern; they are stacked implicitly. `_$:` (muted) lines are ignored. Multi-line patterns: body continues until next `$:` / `_$:` line. Limitation: continuation lines must not start with `$:` or `_$:`. |
| Leading-dot numbers | ✅ nativo (Fase 5) | `.4` accepted everywhere as `0.4` (affects all numeric method args in CodeParser). |

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

## Audio chain (per sample layer) — updated P0-4

```
AVAudioPlayerNode → AVAudioUnitVarispeed → AVAudioUnitEQ (lowpass, bypassed)
  → AVAudioMixerNode (pan)
  → OrbitBus.gain (AVAudioMixerNode) → OrbitBus.reverb → OrbitBus.delay
  → mainMixer
```

`pan` node always in chain at center (0) unless `.pan()` called.
Reverb/delay are on the shared orbit bus (not per-layer). Each orbit gets one bus.
Per-event lpf/hpf (samples): applied as buffer preprocessing before scheduling (biquad, Audio EQ Cookbook).

## Audio chain (per synth layer) — updated P0-3/P0-4

```
AVAudioSourceNode (voice pool, 8 voices, per-voice biquad LPF/HPF inside render block)
  → AVAudioUnitEQ (bypass=true, kept in graph for topology stability)
  → AVAudioUnitDistortion (shape/distort)
  → AVAudioUnitEQ/3bands (vowel formant)
  → AVAudioMixerNode (pan)
  → OrbitBus.gain (AVAudioMixerNode) → OrbitBus.reverb → OrbitBus.delay
  → mainMixer
```

- Polyphony: 8-voice pool per synth type. Voice steal: LRU (oldest birth).
- AVAudioUnitEQ bands permanently bypassed (bypass=true); biquad LPF/HPF is per-voice inside the render block.
- **Per-voice biquad (P0-3)**: BiquadFilter struct (direct-form II transposed). Coefficients from Audio EQ Cookbook (Robert Bristow-Johnson, public domain). 64-sample linear ramp on cutoff changes to avoid clicks (coefficients recomputed inline without resetting z1/z2 delay lines). Two simultaneous events with different lpf → independent filter state per voice.
- ADSR envelope is computed per-voice in the render block (no Apple AU needed for envelope).
- **Sample-accurate onset (Bug 2 fix)**: Each voice stores its scheduled `startHostSeconds` (absolute host-clock time, same domain as `mach_absolute_time`). The AVAudioSourceNode render block reads `AudioTimeStamp.mHostTime` of frame 0, converts to seconds, and computes `startFrame = Int((startHostSeconds − bufferStart) × sampleRate)`. The voice renders silence for frames 0..<startFrame and audio from startFrame onward — eliminating the pre-fix up-to-lookahead (400ms) early triggering.
- **Synth headroom (Bug 3 fix, empirically calibrated 2026-07-23)**: A fixed factor `synthHeadroom = 0.3` is applied in the render block (`sample × gain × 0.3`). This factor was empirically validated against Strudel's real output using `WebProbe --record` (WKUserScript monkey-patch, ScriptProcessorNode capture). See [Volume Calibration](#volume-calibration-2026-07-23) below.
- **Triangle waveform amplitude fix (2026-07-23)**: The triDrive formula for the leaky integrator was corrected from `k=(1−L)/(1−Lpow)` to `k=(1−L)×(1+Lpow)/(1−Lpow)`. The original formula ignored the cross-half residue and produced steady-state peaks at ~0.51 instead of 1.0, making triangle ~50% too quiet. The corrected formula gives peak=1.0 at all frequencies. See `SynthVoice.swift trigger()` for derivation.

## Resonance note (updated P0-3)

`resonance` in Strudel is a filter Q parameter (range 0..50 per public docs).

**P0-3 (synths / sample biquad):** Q is passed directly to the Audio EQ Cookbook biquad formula:
`alpha = sin(w0) / (2 × Q)`, where `w0 = 2π × fc / fs`. Q is clamped to [0.01, 50].
Default Q = 0.707 (Butterworth — maximally flat passband).

| Q | Character |
|---|---|
| 0.707 | Butterworth (default, maximally flat) |
| 1 | Slightly peaked |
| 5 | Noticeable resonance peak |
| 10 | Strong self-oscillation tendency |
| 50 | Very sharp (near self-oscillation) |

The old AVAudioUnitEQ bandwidth mapping (`bandwidth = clamp(2.0/Q, 0.05, 5.0)`) is no longer used for synths or samples; the EQ node is permanently bypassed in both chains.

## Synth oscillators (Fase 3)

All oscillators are band-limited using polyBLEP corrections (standard public-domain DSP technique).

| Waveform | Method | Note |
|---|---|---|
| `sine` | sin(2π·phase) | Trivial, alias-free |
| `sawtooth` | naive saw + polyBLEP at phase=0 | Suppresses aliasing at discontinuity |
| `square` | naive square + polyBLEP at 0 and 0.5 | Suppresses aliasing at both transitions |
| `triangle` | leaky integrator of polyBLEP square (leak=0.999) | Corrected drive formula k=(1−L)·(1+Lpow)/(1−Lpow) for peak=1.0 |

## What is NOT supported (Fase 3)

| Feature | Status | Notes |
|---|---|---|
| Negative `speed()` (reverse) | Not supported | Documented. `scheduleSegment` reverse is complex to implement correctly for arbitrary buffers. Document for Fase 4 if needed. |
| `speed()` affecting synth frequency | Not applicable | Synth frequency is computed from MIDI note; speed() is pattern-level only for synths |
| Per-event lpf/hpf/resonance | ✅ Resolved in P0-3 | Synths: per-voice biquad (Audio EQ Cookbook). Samples: per-event buffer preprocessing. |
| Per-event room/delay | Orbit-bus compromise | room/delay are per orbit bus — last event on that orbit wins. Better than per-chain (same orbit shares reverb tail as in Strudel); room/delay cannot differ within the same orbit. |
| Offline filter audio test | Not tested | AVAudioUnitEQ requires a running engine. Parameter mapping is unit-tested. Actual DSP filter roll-off trusted to Apple |

---

## Fase 4: DSP / Textures

### Audio chain (Fase 4 — updated for P0-3/P0-4)

```
Sample: AVAudioPlayerNode → AVAudioUnitVarispeed → AVAudioUnitEQ (bypassed)
  → AVAudioUnitDistortion (shape/distort, dry default)
  → AVAudioUnitEQ/3bands (vowel formant, bypassed default)
  → AVAudioMixerNode (pan)
  → OrbitBus.gain → OrbitBus.reverb → OrbitBus.delay → mainMixer

Synth: AVAudioSourceNode (voice pool, per-voice biquad LPF/HPF)
  → AVAudioUnitEQ (bypass=true)
  → AVAudioUnitDistortion (shape/distort)
  → AVAudioUnitEQ/3bands (vowel)
  → AVAudioMixerNode (pan)
  → OrbitBus.gain → OrbitBus.reverb → OrbitBus.delay → mainMixer
```

### shape / distort (saturation)

- Preset: `AVAudioUnitDistortionPreset.multiDistortedFunk` (raw value 9).
  Selected as the warmest/softest analog-style overdrive available in the native API.
- Mapping: `x → wetDryMix = x × 100` (0 = dry, 100 = fully saturated).
- `shape` and `distort` both use the same preset. If both are set in the same hap,
  `distort` takes precedence. Strudel uses distinct distortion curves for shape/distort
  (e.g. soft-clip vs hard-clip variants) — this approximation uses a single preset for both.
  Documented compromise.
- Per-chain: last-set value wins per layer (same limitation as lpf/room).

### crush (bitcrusher)

- Formula (public domain): `quantize(s, n) = round(s × 2^(n-1)) / 2^(n-1)`
- Range: n = 1..16. Values below 1 clamped to 1; above 16 clamped to 16.
- Samples: applied as AVAudioPCMBuffer pre-processing per event (quantised copy scheduled).
- Synths: applied per sample inside the SynthVoice render block, post-ADSR.
- At n=16: ~transparent (32768 levels, step ≈ 3×10⁻⁵). At n=4: 8 levels (heavy lo-fi).
- Patroneable.

### vowel (formant filter)

Formant frequencies (Hz) — Peterson & Barney (1952), approximate midpoint average:

| Vowel | Phoneme | F1 | F2 | F3 |
|---|---|---|---|---|
| `a` | /ɑ/ "father" | 730 | 1090 | 2440 |
| `e` | /ɛ/ "bed"    | 530 | 1840 | 2480 |
| `i` | /iː/ "see"  | 390 | 1990 | 2550 |
| `o` | /ɔ/ "thought" | 570 | 840 | 2410 |
| `u` | /uː/ "food" | 440 | 1020 | 2240 |

- Implementation: AVAudioUnitEQ with 3 parametric (bell) bands, gain=+6dB, bandwidth=0.5 octaves.
- Bypassed by default; activated on each event that has a vowel field.
- Per-chain: all events in the same layer share the last-set vowel.
- Patroneable: `vowel("<a o>")` alternates per cycle (verified).

### chop / striate (granular)

Semantics verified against oracle (Strudel black-box):

**chop(n)**: cuts EACH event into n sequential sub-events:
- Each sub-event has: time = 1/n of original slot; begin = k/n; end = (k+1)/n
- Event count multiplied by n: `s("pad bell").chop(2)` → 4 events
- Scheduler plays sub-buffer: `AVAudioPCMBuffer[frameStart:frameEnd]` (O(frameCount) copy per event)

**striate(n)**: assigns chunk (i mod n) to event i — does NOT create new events:
- Event i in sorted order gets: begin = (i mod n)/n; end = ((i mod n)+1)/n
- For `s("pad").striate(4)`: 1 event, chunk 0 → begin=0, end=0.25
- For `s("pad bell").striate(2)`: 2 events — pad→chunk0, bell→chunk1
- Key difference from chop: striate interleaves existing events; chop multiplies them

### chorus / phaser — NOT IMPLEMENTED

**chorus**: The task brief notes that AVAudioUnitDelay-based approximation (~20ms, low feedback,
no modulation) would not qualify as "honest". True chorus requires modulated delay (not natively
available as a configurable AVAudioUnit). A custom implementation would require an AVAudioSourceNode
tap or AU, which is disproportionate for a motor demo.
**Decision**: omitted. CodeParser accepts `chorus()` without error (logs warning, no-op).

**phaser**: Requires a chain of all-pass biquad sections with LFO modulation. Implementable
in principle inside a custom render block, but the result would sound wrong at all parameter
values without calibrated feedback and notch spacing. Not worth including as a broken
approximation in a production-quality motor.
**Decision**: omitted. CodeParser accepts `phaser()` without error (logs warning, no-op).

Both are documented in COMPATIBILITY.md (this file) with the rationale above.

## What is NOT supported (Fase 4)

| Feature | Status | Notes |
|---|---|---|
| `chorus` | Not implemented | See chorus/phaser note above |
| `phaser` | Not implemented | See chorus/phaser note above |
| Per-event shape/distort (unique per event in same layer) | Per-chain compromise | Last-set value wins per layer. lpf/hpf are now per-event (P0-3); shape/distort remain per-chain |
| Per-event vowel (unique per event in same layer) | Per-chain compromise | All events in the same layer see the last-set vowel |
| Per-orbit room/delay uniqueness | Orbit-bus compromise | All layers on the same orbit share one reverb+delay bus; room/delay params set by last event dispatched on that orbit |
| `chop`/`striate` on synths | Pattern-level only | begin/end fields are ignored in the synth scheduler path (synth sound is generated; no sample buffer to segment) |
| Offline distortion/vowel audio test | Not tested offline | AVAudioUnit DSP requires a running engine. Parameter mappings (wetDryMix, band frequencies) are unit-tested |

---

## Fase 5: Drum Sample Bank

### Available samples

Both engines (Strudel WebView and MiniEngine) use the same files from `Samples/`.

| Canonical name | File (flat) | File (tr909) | File (tr808) | Origin (repo) |
|---|---|---|---|---|
| `bd`  | `bd.wav`  | `tr909/bd.wav`  | `tr808/bd.wav`  | RolandTR909/rolandtr909-bd/Bassdrum-01.wav ; RolandTR808/rolandtr808-bd/BD0000.WAV |
| `sd`  | `sd.wav`  | `tr909/sd.wav`  | `tr808/sd.wav`  | RolandTR909/rolandtr909-sd/sd01.wav ; RolandTR808/rolandtr808-sd/SD0000.WAV |
| `hh`  | `hh.wav`  | `tr909/hh.wav`  | `tr808/hh.wav`  | RolandTR909/rolandtr909-hh/hh01.wav ; RolandTR808/rolandtr808-hh/CH.WAV |
| `oh`  | `oh.wav`  | `tr909/oh.wav`  | `tr808/oh.wav`  | RolandTR909/rolandtr909-oh/oh01.wav ; RolandTR808/rolandtr808-oh/OH00.WAV |
| `cp`  | `cp.wav`  | `tr909/cp.wav`  | `tr808/cp.wav`  | RolandTR909/rolandtr909-cp/cp01.wav ; RolandTR808/rolandtr808-cp/cp0.wav |
| `rim` | `rim.wav` | `tr909/rim.wav` | `tr808/rim.wav` | RolandTR909/rolandtr909-rim/rs01.wav ; RolandTR808/rolandtr808-rim/RS.WAV |
| `lt`  | `lt.wav`  | `tr909/lt.wav`  | `tr808/lt.wav`  | RolandTR909/rolandtr909-lt/lt01.wav ; RolandTR808/rolandtr808-lt/LT00.WAV |
| `mt`  | `mt.wav`  | `tr909/mt.wav`  | `tr808/mt.wav`  | RolandTR909/rolandtr909-mt/mt01.wav ; RolandTR808/rolandtr808-mt/MT00.WAV |
| `ht`  | `ht.wav`  | `tr909/ht.wav`  | `tr808/ht.wav`  | RolandTR909/rolandtr909-ht/ht01.wav ; RolandTR808/rolandtr808-ht/HT00.WAV |
| `cr`  | `cr.wav`  | `tr909/cr.wav`  | `tr808/cr.wav`  | RolandTR909/rolandtr909-cr/cr01.wav ; RolandTR808/rolandtr808-cr/CY0000.WAV (cymbal) |
| `rd`  | `rd.wav`  | `tr909/rd.wav`  | `tr808/rd.wav`  | RolandTR909/rolandtr909-rd/rd01.wav ; **TR808 has no native ride — tr808_rd maps to CY0000.WAV (cymbal substitute)** |
| `pad` | `pad.wav` | — | — | Original project asset, preserved |
| `bell`| `bell.wav`| — | — | Original project asset, preserved (note-mapped, c4 base) |

Source: `github.com/ritchse/tidal-drum-machines` (CC licence — same set as strudel.cc).
Clone: `git clone --depth 1 https://github.com/ritchse/tidal-drum-machines.git` (shallow, in /tmp — not bundled in repo).

### bank() status: ✅

`bank("tr909")` and `bank("tr808")` work in both engines.
- **Strudel (WebView)**: samples registered with `tr909_*` / `tr808_*` keys in `samples({...}, base)`. Strudel's native `.bank()` method prepends the bank name automatically.
- **MiniEngine**: `EngineAdapter` enumerates `Samples/` recursively; subfolder files get key `subfolder_filename` (e.g. `tr909/bd.wav` → `"tr909_bd"`). Scheduler resolves effective key as `"\(bank)_\(s)"` when `bank` field is present.

### $: status: ✅

`$:` top-level parallel pattern syntax is implemented in CodeParser (MiniEngine).
Multi-line continuation is supported (a pattern body continues until the next `$:` or `_$:` line).
`_$:` (muted) patterns are silently ignored.

The Strudel WebView side already supports `$:` natively via its `evaluate()` function.

### ADSR on samples note

When `dec()` / `att()` / `sus()` / `rel()` (or their long forms) are set on a sample pattern,
an ADSR amplitude envelope is applied to the PCM buffer before scheduling.
If **none** of the ADSR parameters are set, the buffer is passed through unchanged — no change
in sound for existing patterns that don't use ADSR. This is the backward-compatibility guarantee.

---

## Volume Calibration (2026-07-23)

**Method:** `WebProbe --record` mode. A `WKUserScript` injected at `.atDocumentStart` patches
`AudioNode.prototype.connect` before `strudel-bundle.js` loads. Any node connecting to
`ctx.destination` is also connected to a `ScriptProcessorNode(4096, 2, 2)` that accumulates
channel-L samples in `window.__captureChunks`. After N seconds, Swift extracts samples
via `callAsyncJavaScript` (base64 chunks) and computes RMS ignoring the first 0.3s warmup.
sampleRate = 44100 Hz in all cases. All patterns at `cps=0.5` (1 cycle = 2 seconds).

### Strudel reference (real WebView output)

| Pattern | RMS | Ratio/bd |
|---|---|---|
| `s("bd*4").gain(0.95)` | 0.213416 | 1.000 (reference) |
| `note("a4").sound("triangle").gain(0.5)` | 0.052425 | 0.2457 |
| `note("a4").sound("sawtooth").gain(0.5)` | 0.044148 | 0.2069 |
| `note("a4").sound("sine").gain(0.5)` | 0.064196 | 0.3008 |
| `note("a4").sound("square").gain(0.5)` | 0.076606 | 0.3590 |
| `stack(bd*4, triangle a4 e5)` | 0.224318 | — |

### MiniEngine (after calibration, synthHeadroom=0.3)

After fixing the triangle triDrive formula, all four waveforms are within ±30% of Strudel:

| Waveform | RMS (mini) | Ratio/bd (mini) | vs Strudel |
|---|---|---|---|
| bd | 0.2112 | 1.000 | — |
| triangle | 0.0514 | 0.2435 | −1% ✓ |
| sawtooth | 0.0513 | 0.2434 | +18% ✓ |
| sine | 0.0668 | 0.3164 | +5% ✓ |
| square | 0.0889 | 0.4204 | +17% ✓ |

**Tolerance target: ±30% (≈±2.3 dB).** All waveforms are within tolerance.

**Before the triangle fix** (wrong triDrive formula), triangle was at **−49%** (−5.8 dB) relative to
Strudel. The formula produced steady-state peaks at 0.51 instead of 1.0. After fix: −1%.

### Regression test

`LiveEngineTests.testSynthBdRatioMatchesStrudel` measures the ratio RMS_triangle/RMS_bd on the
live engine and asserts it falls in [0.1719, 0.3193] (Strudel reference 0.2457 ±30%).

### synthHeadroom decision

`synthHeadroom = 0.3` is empirically validated. No change needed.
The triangle amplitude fix (triDrive formula) brought triangle into range without changing the
global headroom factor. A single global headroom is sufficient (spread across waveforms is ≤1.5×
after the fix: saw 1.17, sine 1.05, square 1.17, triangle 0.99).

---

## P0-2: Señales continuas (2026-07-23)

### Semántica confirmada contra oracle

| Propiedad | Valor confirmado |
|---|---|
| Punto de muestreo | `span.begin` (NO el punto medio). Oracle: sine.queryArc(0, 1/8) → value=0.5 = sine(0) |
| whole de un hap de señal | `nil` — sin estructura discreta |
| Fase de sine | t=0→0.5, t=0.25→1.0 (pico), t=0.5→0.5, t=0.75→0.0 (valle) |
| segment(n) — whole | `whole = part = [k/n, (k+1)/n)` (estructura discreta; no nil) |
| gain(signal) en eventos | Señal evaluada en `whole.begin` del evento (appLeft semántica) |
| Coincidencia oracle saw.range(2,4).segment(4) | [2.0, 2.5, 3.0, 3.5] — exacto |

### signal() con callback externo (EEG hook)

```swift
// Swift-only API — para EEG real:
let eegSignal = signal { t in brainFeature.currentValue }
let pattern = s("sawtooth").lpf(eegSignal.range(200, 2000))
```

No hay sintaxis en el editor de código para `signal()` con callback externo.
En el editor se usan los osciladores nombrados (`sine`, `saw`, etc.).

### Osciladores implementados

| Oscilador | Fórmula | Exactitud |
|---|---|---|
| `sine` | (sin(2πt)+1)/2 | Exacta (oracle match bit-a-bit en doubles) |
| `saw` | t mod 1 | Exacta |
| `isaw` | 1 − (t mod 1) | Exacta |
| `square` | floor((t×2) mod 2) | Exacta |
| `cosine` | (cos(2πt)+1)/2 | Exacta |
| `tri` | fastcat(saw, isaw) | Exacta |
| `rand` | hash(t) / 2^64 | **APROXIMACIÓN** — secuencia distinta a Strudel (ver nota) |
| `perlin` | Hermite(rand(floor(t)), rand(floor(t)+1)) | **APROXIMACIÓN** — forma suave, valores distintos |

### Nota sobre rand y perlin

**rand**: Strudel usa un algoritmo xorshift legacy (`__timeToIntSeed` + `__xorwise`) con granularidad 1/536870912. El MiniEngine usa un hash splitmix64 de 64-bit sobre la misma granularidad. La distribución es uniforme [0,1) y el determinismo está garantizado (mismo t → mismo valor), pero la secuencia exacta difiere. Para el EEG esto es correcto: importa la distribución, no los valores exactos.

**perlin**: Strudel implementa perlin con un hash diferente (murmur-based). El MiniEngine usa interpolación cúbica de Hermite (smoothstep 3f²−2f³) entre valores `rand` en boundaries de ciclo entero. La forma es suave y acotada [0,1). Los valores exactos difieren de Strudel.

### Suavidad intra-evento

El valor de un control modulated por señal (e.g. `.lpf(sine.range(200,2000))`) se evalúa UNA VEZ por evento, en `whole.begin`. Dentro del evento, el valor es constante (no hay interpolación per-sample).

La interpolación continua por-sample (suavidad real entre eventos) está parcialmente resuelta con P0-3: los biquads de synth tienen rampa de 64 muestras en el cutoff. Para otros parámetros (gain, pan, room) el valor se evalúa una vez por evento.

### Estado EEG hook

`signal { t in ... }` está disponible como API pública Swift. Para usar en el EEG:

```swift
// En la app, cuando se recibe una nueva feature EEG:
let alphaSignal = signal { t in eegEngine.alphaValue }
let codePattern = try CodeParser().parse("s(\"sawtooth\").note(\"c3\")")
let modulatedPattern = codePattern.lpf(alphaSignal.range(200, 2000))
```

La integración completa del ciclo EEG→audio (scheduling continuo de señal) requiere que el scheduler consulte la señal en cada buffer de audio (P0-3+). La infraestructura de patrones está lista.

---

## P0-3: Efectos por evento (2026-07-23)

### Cambio arquitectónico

Se elimina el "per-chain compromise" para lpf/hpf/resonance:

| Componente | Antes | Ahora |
|---|---|---|
| Synth lpf/hpf | AVAudioUnitEQ per-layer (último evento wins) | Biquad per-voice (independiente por voz) |
| Sample lpf/hpf | AVAudioUnitEQ per-layer (último evento wins) | Buffer preprocessing per-event (copia biquadificada) |
| resonance (Q) | Bandwidth octaves en AVAudioUnitEQ | Q directo al biquad (fórmula Audio EQ Cookbook) |
| room/delay | AVAudioUnitReverb/Delay per-layer | Orbit bus compartido por orbita (ver P0-4) |

### Biquad: Audio EQ Cookbook (dominio público)

Implementación: direct-form II transposed, single-precision accumulation in Double.

**Lowpass:**
```
w0 = 2π × fc / fs
alpha = sin(w0) / (2Q)
b0 = (1 − cos(w0)) / 2,  b1 = 1 − cos(w0),  b2 = (1 − cos(w0)) / 2
a0 = 1 + alpha,  a1 = −2 cos(w0),  a2 = 1 − alpha
H_norm: divide all by a0
```

**Highpass:**
```
b0 = (1 + cos(w0)) / 2,  b1 = −(1 + cos(w0)),  b2 = (1 + cos(w0)) / 2
a coefficients: same as lowpass
```

Default Q = 0.707 (Butterworth). fc clamped to [1, fs×0.4999]. Q clamped to [0.01, 50].

### 64-sample ramp (anti-click)

On voice trigger: `lpfCurrent` = last cutoff, `lpfTarget` = new cutoff, `lpfRampLeft = 64`.
In the render block, for each of the 64 ramp samples: cutoff = current + (target-current) × (64-rampLeft)/64,
coefficients recomputed inline, biquad state z1/z2 preserved (not reset). After ramp: stable at target.
On hard retrigger: z1/z2 reset to avoid state accumulation from previous note.

### Samples: buffer preprocessing

`lpfBuffer(_ buffer: AVAudioPCMBuffer, cutoffHz: Double, q: Double) -> AVAudioPCMBuffer`
`hpfBufferApply(_ buffer: AVAudioPCMBuffer, cutoffHz: Double, q: Double) -> AVAudioPCMBuffer`

Applied in `dispatchHap()` before scheduling. Same biquad formulas. Q from resonance field (default 0.707).
Parameters are constant per event (no ramp needed for buffer-mode).

### AudioValidate: T10 (per-voice biquad)

Test T10 added to `Sources/AudioValidate/main.swift`:
- T10a: `note("a3").sound("sawtooth").lpf(200)` → fundamental 220 Hz detected in OfflineVoice output
- T10b: same → energy band 800-8000 Hz attenuated ≥ -20 dB (actual: ~-25 dB, well below -24 dB theoretical)

`OfflineVoicePool` updated: `OVBiquadFilter` struct + `lpfHz` threading through `PendingEvent` → `OfflineVoice.trigger()` → render loop.

Total AudioValidate: **24/24 PASS** (22 original + T10a + T10b).

---

## P0-4: orbit(n) — Buses de efectos por órbita (2026-07-23)

### Semántica

`.orbit(n)` rutas una capa a un bus de efectos independiente. Default: orbit=1.
Múltiples capas en la misma órbita comparten reverb+delay (mismo comportamiento que Strudel).

### Implementación: OrbitBus

```swift
final class OrbitBus {
    let gain: AVAudioMixerNode     // duck target para P1-5
    let reverb: AVAudioUnitReverb  // room → wetDryMix = room × 100
    let delay: AVAudioUnitDelay    // delay wet/time/feedback
}
```

Cadena: `panner → OrbitBus.gain → OrbitBus.reverb → OrbitBus.delay → mainMixer`

Buses creados on-demand en `play()` (pre-scan de orbits). Destruidos en `stop()` (detach + removeFromEngine).

### Compromiso documentado (orbit bus)

- room y delay params: actualizados por el último evento despachado en esa órbita.
- Mejor que per-chain (antes): todas las capas de la misma órbita comparten el mismo tail de reverb (correcto, igual que Strudel).
- Peor que per-event: dos eventos en la misma órbita con room distinto usan el valor del último. Documentado.
- room/delay NO son per-event para samples (la infraestructura de preprocessing de buffer puede extenderse en el futuro si se requiere).

### CodeParser / ControlPattern

`orbit()` aceptado en el editor: `.orbit(1)`, `.orbit(2)`, `.orbit("1 2")`.
`"orbit"` añadido a `knownMethods` en CodeParser.
Default `PatternScheduler.defaultOrbit = 1` (verificado contra strudel.cc/learn/effects docs).

---

## P1 Features — Funcionalidad Avanzada (2026-07-23)

Todos los P1 implementados y en verde (416 tests, 0 fallos; AudioValidate 24/24 PASS; build release OK).

### P1-5: duck() / duckattack() / duckdepth() — sidechain ducking

Los eventos de una capa atenúan el `OrbitBus.gain.outputVolume` de otra órbita.

| Parámetro | Default | Rango | Notas |
|---|---|---|---|
| `duck(orbit)` | — | Integer orbit index | Órbita target a atenuar. Entero. |
| `duckattack(x)` | 0.1s | ≥ 0.01s (clamped) | Tiempo de recuperación (attack del gain ramp back to 1.0) |
| `duckdepth(x)` | 1.0 | [0.0, 1.0] | 1.0 = duck completo (volumen baja a 0); 0 = sin efecto |

**Semántica confirmada:** duck es un efecto de sidechain — cuando la capa A tiene `.duck(2)`, cada evento de A baja el `outputVolume` del OrbitBus de orbit=2. El volumen se recupera gradualmente en `duckattack` segundos.

**Implementación:**
- `scheduleDuck()` en `PatternScheduler.swift`: envía `poolQueue.asyncAfter` a 10ms de resolución.
- Inicio: `gain.outputVolume = 1.0 - duckdepth` (instantáneo al onset del evento).
- Recuperación: `nSteps = ceil(duckattack / 0.01)` pasos de `volumeStep = duckdepth / nSteps` cada 10ms.
- Thread-safety: todos los accesos a `gain.outputVolume` en `poolQueue`.

**Compromiso documentado:** la resolución del ramp es 10ms (no sample-accurate). Strudel usa audio-rate sidechain vía Web Audio GainNode automation. En AVAudioMixerNode no hay automation curves — se usa `DispatchQueue.asyncAfter` que tiene resolución de ~10ms en práctica. Para música de producción a 120bpm, 10ms es suficiente para ataques musicalmente relevantes.

### P1-6: lpenv() / hpenv() / lpq() / hpq() — filter envelope modulation

| Parámetro | Tipo | Notas |
|---|---|---|
| `lpenv(octaves)` | Double | Módulo de apertura del LPF en octavas durante el ataque del ADSR |
| `hpenv(octaves)` | Double | Módulo de apertura del HPF en octavas (positivo = sube cutoff en ataque) |
| `lpq(x)` | alias | `lpq(x)` = `resonance(x)` — mismo campo en el control map |
| `hpq(x)` | alias | `hpq(x)` = `resonance(x)` — mismo campo en el control map |

**Fórmula confirmada:**
```
effective_cutoff = lpfBase × 2^(lpenv × env(t))
```
Donde `env(t)` es la envolvente ADSR normalizada [0, 1] en el momento `t`.

- `lpfBase`: valor de `lpf()` en el hap (default: 20000 Hz si lpf no está seteado).
- `hpfBase`: valor de `hpf()` en el hap (default: 20 Hz si hpf no está seteado).
- Recompute de coeficientes: cada 64 muestras (bloque), en-place (z1/z2 preservados — sin discontinuidades).
- `lpenvOctaves = 0` → sin modulación (equivale al comportamiento P0-3).
- Valores negativos permitidos: `lpenv(-2)` cierra el filtro en el ataque.

**Ejemplos:**
```swift
// lpf=300 Hz, lpenv=3 → cutoff en peak: 300 × 2^3 = 2400 Hz (totalmente abierto)
note("c3").sound("sawtooth").lpf(300).lpenv(3)

// lpq = resonance alias
note("c3").sound("sawtooth").lpf(400).lpq(8)  // resonancia Q=8
```

**lpq / hpq:** verificados como aliases de `resonance` (mismo campo `"resonance"` en el control map).
Confirmado vía strudel.cc docs públicos (`lpq` = Q del LPF).

**AudioValidate:** `testLpenvOpensFilterDuringAttack` y `testLpenvSpectrallyCentroidHigherDuringAttack` confirman que el filtro se abre durante el ataque y se cierra durante el sustain. Estos tests están en `P1Tests.swift` (Swift, render offline). No se añadieron nuevos tests a `AudioValidate/main.swift` para no afectar el conteo 24/24 existente.

### P1-7: add() — combinación aritmética de patrones (appLeft)

Implementado con semántica **appLeft**: la estructura (whole, part) viene del patrón **base**; el argumento de `add()` se consulta sobre el `whole` del hap base.

**Semántica confirmada:**
- `add(other)` → para cada hap base, consulta `other` sobre el `whole` del hap base.
- Resultado: un hap por cada par (base, other) cuyo dominio se solapa.
- Para campos numéricos presentes en ambos: `result[key] = base[key] + other[key]`.
- Para campos ausentes en base: `result[key] = other[key]` (adoptado del argumento).
- Campos no numéricos (strings): no modificados.
- Argumento `other` tiene 2 haps simultáneos (e.g. `note("[0,.12]")`): produce cartesian product = 2 haps de salida por hap base.

**Casos verificados contra oracle:**
| Expresión | Resultado |
|---|---|
| `note("c3").add(note("12"))` | MIDI 60 (C4) — transpone +12 semitonos |
| `note("c3").add(note("7"))` | MIDI 55 (G3) — transpone +7 semitonos |
| `note("c3").add(note("[0,.12]"))` | 2 haps: MIDI 48.0 + MIDI 48.12 (detune) |
| `n("0 2").add(n("7"))` | 2 haps: n=7, n=9 (preserva estructura de 2 eventos) |

**CodeParser:** `add(note("..."))` y `add(n("..."))` parseados vía `parseAddArgument()`.
Soporte: `note("literal")`, `n("literal")`, y números directos.

### P1-8: postgain() / size() / roomsize() / fb() / dt()

| Función | Alias de | Campo | Default | Notas |
|---|---|---|---|---|
| `postgain(x)` | — | `"postgain"` | 1.0 | Multiplicador de gain post-ADSR para synths; `player.volume *= postgain` para samples |
| `size(x)` | — | `"size"` | — | Tamaño del reverb (0..1) → preset de AVAudioUnitReverb |
| `roomsize(x)` | `size(x)` | `"size"` | — | Alias de size |
| `fb(x)` | `delayfeedback(x)` | `"delayfeedback"` | — | Alias de delayfeedback |
| `dt(x)` | `delaytime(x)` | `"delaytime"` | — | Alias de delaytime |

**postgain:**
- Synths: `out = sample × env × gain × postgain × synthHeadroom` — aplica en el render block.
- Samples: `group.player.volume = Float(gain × postgain)` — aplica en dispatchHap.
- Efecto: multiplicativo con `gain`. `postgain(0.5)` con `gain(1.0)` → mitad del volumen.
- Verificado: `testPostgainMultipliesVoiceOutput` confirma ratio de RMS ≈ 0.5 (±2%).

**size() — mapeo discreto (APROXIMACIÓN DOCUMENTADA):**

Strudel usa Freeverb (reverb algorítmico con `roomSize` continuo 0..1). AVAudioUnitReverb usa impulse responses con presets discretos. Mapeo elegido por progresión perceptual:

| size | Preset |
|---|---|
| < 0.3 | `.smallRoom` |
| < 0.6 | `.mediumHall` (default de orbit bus) |
| < 0.8 | `.largeHall` |
| ≥ 0.8 | `.cathedral` |

Nota: el cambio de preset en AVAudioUnitReverb es inmediato (no interpolado). A diferencia de Strudel donde el tamaño afecta el decaimiento continuo del reverb, aquí hay un salto cualitativo al cruzar los umbrales. Documentado como aproximación.

**fb() / dt():** aliases puros (redirigen al mismo campo de control map que `delayfeedback`/`delaytime`). Sin compromiso — comportamiento idéntico.

### Defaults P1 (documentados)

| Parámetro | Default | Fuente |
|---|---|---|
| `duckattack` | 0.1s | Strudel superdough docs (public) |
| `duckdepth` | 1.0 | Strudel docs: duck completo por defecto |
| `lpenv` | 0.0 | Sin modulación |
| `hpenv` | 0.0 | Sin modulación |
| `postgain` | 1.0 | Sin cambio de gain |
| Block size lpenv coef update | 64 samples | Balance CPU/suavidad (igual que ramp P0-3) |

### Test coverage P1

`P1Tests.swift` — 38 tests, todos PASS:
- Control field parsing: duck, duckattack, duckdepth, lpenv, hpenv, lpq (=resonance), hpq (=resonance), postgain, size, roomsize (=size), fb (=delayfeedback), dt (=delaytime)
- CodeParser parsing: todos los métodos anteriores
- Duck ramp math: validación unitaria de los parámetros del ramp (startVolume, nSteps, volumeStep, recovery)
- lpenv audio (offline render): 2 tests espectrales que confirman el filtro se abre en ataque (cutoff ~2400Hz) y se cierra en sustain (cutoff ~908Hz)
- postgain multiplica RMS: ratio = 0.5 ± 2%
- add() transposición: C3+12=C4, C3+7=G3, cartesian product chord, estructura preservada
- Regresión: resonance sigue funcionando después de añadir lpq/hpq
