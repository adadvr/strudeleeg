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
| `rev` | ❌ no | Invert pattern |
| `ply(n)` | ❌ no | Repeat each event n times (rolls) |
| `every(n, f)` | ❌ no | Apply transformation every n cycles |
| `sometimes` / `often` / `rarely` | ❌ no | Probabilistic application (needs RNG seed) |
| `off(t, f)` | ❌ no | Phase-shifted copy |
| `jux(f)` | ❌ no | Stereo split with transform |
| `struct("...")` | ❌ no | Boolean structure pattern |
| `sound(...)` (synths) | ❌ no | Oscillator synths (Fase 3) |
| `attack`/`decay`/`sustain`/`release` | ❌ no | ADSR envelope (Fase 3) |
| `lpf`/`hpf` | ❌ no | High-pass filter (Fase 3) |
| `speed(x)` | ⚠️ parcial | Pitch via varispeed is done via `note()`. Explicit speed control not exposed |
| `shape` / `distort` | ❌ no | Saturation (Fase 4) |
| `chop` / `striate` | ❌ no | Granular (Fase 4) |
| `crush` | ❌ no | Bitcrusher (Fase 4) |
| `vowel` | ❌ no | Formant filter (Fase 4) |

## Defaults (documented)

| Parameter | Default | Notes |
|---|---|---|
| `cps` | 0.5 | 1 cycle = 2 seconds |
| `delay` wet | 0 (dry) | No echo unless `.delay(x)` called |
| `delaytime` | 0.25s | Used when `.delay()` called without explicit delaytime |
| `delayfeedback` | 0.5 (50%) | Used when `.delay()` called without explicit delayfeedback |
| `pan` | 0 (center) | No pan node applied unless `.pan()` called |
| Scale base octave | C3 = MIDI 48 | `n(0).scale("C:minor")` = 48 (verified with Strudel oracle) |

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
