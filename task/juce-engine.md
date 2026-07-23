# Tareas — Tercer motor JUCE (columna [juce])

Plan: `~/.claude/plans/de-mi-proyecto-con-concurrent-newt.md`
Alcance: solo macOS ahora, preparado para iOS. Reusar MiniEngine Swift (patterns). Paridad completa FX.
> Borrar este archivo al terminar todo.

## Fase 0 — Spike build/integración
- [x] Crear `StrudelJuce/` (CMake basado en Eno, sin LTO para xcframework)
- [x] CMake parametrizado: macOS arm64 ahora, flag iOS listo
- [x] C API `strudel_*` agnóstico de plataforma (header sin deps C++/JUCE)
- [x] Empaquetar `.xcframework` (estática macOS + headers)
- [x] `binaryTarget` + `StrudelJuceC` module en Package.swift raíz
- [x] Test tone sonando desde Swift (JuceProbe: device abierto + tono 440Hz OK)

## Fase 1 — Desacoplar AudioBackend en MiniEngine
- [x] ScheduledEvent + PatternEventExtractor (extracción neutral compartida)
- [x] scheduleWindow refactorizado a dispatch(ScheduledEvent); AVAudio intacto
- [x] Loop de timing compartido; extractor reutilizable por JUCE
- [x] ValidateEvents ALL PASS + 511 tests, 0 fallos

## Fase 2 — Núcleo synth JUCE
- [x] `StrudelVoice` — port VERBATIM de SynthVoice.swift (polyBLEP, biquad RBJ, ADSR, triangle drive, headroom 0.3, lpenv/hpenv, crush, sample-accurate). StrudelDSP.h compartido.
- [x] FIFO SPSC (juce::AbstractFifo) + cola pending audio-owned + reloj por índice de muestra
- [x] Reloj Swift↔JUCE: JucePatternScheduler pasa delaySeconds por evento
- [x] C API schedule_synth + all_notes_off; JuceEngine wrapper + JucePatternScheduler (reusa PatternEventExtractor)
- [x] playJuce conectado; JuceProbe synth OK (device abierto, secuencia sawtooth+lpf)
- [ ] Validar de oído A/B/C con patrón de synth (pendiente usuario)

## Fase 3 — Samples JUCE
- [x] `StrudelSampleVoice` (repitch interp lineal, begin/end, ADSR, LPF/HPF en TIEMPO REAL por voz — mejor que preproceso AVAudio)
- [x] load_sample/schedule_sample C API; JuceEngine.loadSample(AVAudioPCMBuffer); preload local en JucePatternScheduler
- [ ] Samples REMOTOS (SampleBankManager → PCM → load_sample) — pendiente

## Fase 4 — Paridad FX
- [x] Orbit buses reverb (juce::Reverb) + delay estéreo con feedback; ruteo por orbit; setOrbitFX
- [x] Filtros MEJORADOS: biquad RBJ en tiempo real por voz (synth con ramp+lpenv/hpenv; sample real-time)
- [x] crush (synth+sample), lpenv/hpenv (synth), postgain, resonance
- [ ] duck/sidechain, distort/shape, vowel (formantes) — pendiente

## Fase 5 — Calibración A/B/C
- [ ] Igualar niveles (equiv. synthHeadroom) con VolumeCalibrate/AudioValidate
- [ ] Afinar filtros/reverb contra oráculo

## Fase 6 — UI + doc iOS
- [x] ContentView 3 columnas (Strudel · Mini Engine · JUCE), PlaySide.juce (adelantado; Play = test tone placeholder)
- [x] README migración iOS en StrudelJuce/
- [ ] Reemplazar placeholder de playJuce por JuceEngineAdapter real (tras Fases 1-4)
