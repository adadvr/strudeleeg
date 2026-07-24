# Tareas — Mini Engine grado producción

## Funcionalidad v1.4 — P4 Sistema de acordes — ✅
- [x] Chords.swift: qualityIntervals (18 calidades), parseChordSymbol, chord() constructor
- [x] chord("Am") → 3 haps simultáneos con campo "note" MIDI (A3=57, C4=60, E4=64)
- [x] chord("<Am E Dm G>") → progresión por slowcat (slowcat semántico de MiniNotationCore)
- [x] .anchor("g5") → inyecta campo _anchor=MIDI en cada hap
- [x] .voicing() → re-disposición compacta cerca del ancla (default c5=72); elimina _anchor
- [x] CodeParser: chord(...) como BASE; voicing()/anchor() como modificadores
- [x] PatternValidator: chord/voicing/anchor en knownMethods y recognizedBase → no se reportan
- [x] ChordsTests.swift: 30 tests (tabla, notas, progresión, voicing, anchor, parser, validador)
- [x] 605 tests totales en verde (575 previos + 30 nuevos); build limpio

## Funcionalidad v1.1 (functionalityv1.1.md) — ✅ COMPLETA
- [x] P0-1 Acordes con coma
- [x] P0-2 Señales continuas: signal(), sine/saw/isaw/tri/square/cosine/rand/perlin + range/rangex/segment
- [x] P0-3 Efectos por evento (biquads Audio EQ Cookbook por voz; buffer por evento en samples)
- [x] P0-4 orbit(n) — buses reverb+delay por orbit
- [x] P1-5 duck/duckattack/duckdepth (sidechain sobre OrbitBus)
- [x] P1-6 lpenv/hpenv + lpq/hpq (alias de resonance verificado)
- [x] P1-7 add() (transposición, detune con acorde)
- [x] P1-8 postgain, size/roomsize (presets discretos), fb/dt
- [x] P1-9/10 alias y $: (rondas anteriores)
- [x] P2 completo: arp, superimpose, stut, echo, iter, chunk, palindrome, hurry, swingBy/swing, mini ?, polimetro {}%n, slice/loopAt
- [x] COMPATIBILITY.md tabla final v1.1
- [x] 476 tests en verde, oracle 71 fixtures / 510 haps, AudioValidate 24/24

## Funcionalidad v1.3 — P3 Expresión y timing — ✅
- [x] Mini-notación `a/n` (operator slow dentro del string): `note("c4/2")` extiende c4 sobre 2 ciclos
- [x] `.late(t)` / `.early(t)` — desplazamiento temporal ±t ciclos (rotR/rotL)
- [x] `.transpose(semitones)` — transpone campo "note" en semitones (overload Int)
- [x] `.velocity(v|mini)` — campo "velocity" (multiplicador de gain, default 1.0)
- [x] `.clip(x|mini)` — campo "clip" (fracción de durationSec: <1=staccato, >1=legato)
- [x] ScheduledEvent: campos velocity + clip; durationSec *= clip; schedulers usan gain×velocity
- [x] CodeParser: late/early/transpose/velocity/clip en knownMethods y parseLayerExpr
- [x] PatternValidator: P3 quitado de suggestions (ya soportados)
- [x] 550 tests en verde (524 previos + 26 nuevos P3); build limpio

## Funcionalidad v1.2 (functionalityv1.2.md, ajustada por Adad) — ✅
- [x] samples('github:user/repo') estilo Strudel (dirt-samples verificado: 218 entradas, branch master)
- [x] Preparado para DO Spaces: samples('https://.../strudel.json') funciona igual (manifest _base o relativo)
- [x] SampleBankManager: caché disco persistente (~/Library/Caches/DemoStrudel/samples), descarga perezosa + prefetch con espera acotada (cache-hits suenan desde el primer ciclo; misses async sin bloquear)
- [x] Variaciones :n con módulo; .n() elige variación
- [x] Nota base remota C2=36; bell local conserva C4=60 (A/B del código semilla intacto)
- [x] Lado Strudel: samples() remoto funciona nativo en el WebView (verificado con sonda: tablas de GitHub sonando, RMS -26dBFS)
- [x] Verificado en vivo Mini Engine: patrón de aceptación tabla/wind/sitar sonando desde GitHub; 2ª pasada sin re-descarga
- [x] 511 tests en verde; RemoteBankLiveTests con guard de red
- [ ] Futuro (cuando exista el bucket DO): subir samples propios + strudel.json y probar samples('https://bucket...') en ambos lados

# (histórico) Tareas — newchanges.md

Plan derivado de [newchanges.md](../newchanges.md). La demo A/B ([devstrudeleeg.md](../devstrudeleeg.md)) está completa; queda su verificación de oído por Adad. Borrar este archivo al terminar todo.

## Pendiente de la demo (manual, Adad)
- [ ] Verificar de oído: código semilla suena igual en ambos lados (fixes de silencio ya aplicados)
- [x] Notarizar el DMG (perfil keychain "demostrudel-notary" con adadros@gmail.com; `bash scripts/notarize.sh` — Accepted + stapled, 2026-07-23)
- [ ] Probar el .dmg **regenerado y notarizado** en otra Mac offline (el DMG anterior crasheaba: fix del resource bundle ya aplicado, 2026-07-23)

## Fase 0 — Fundación ✅
- [x] Motor en su propio Swift package aislado (`MiniEngine/`)
- [x] Core `Pattern<T>` con tiempo racional (Rational/TimeSpan/Hap)
- [x] Parámetros como patrones: `.gain("<0.3 0.8>")` funciona
- [x] Comentarios `//` soportados
- [x] Oracle harness (oracle/generate.mjs → fixtures JSON → OracleTests)
- [x] Subset existente migrado, tests en verde; app demo intacta
- [x] Commit Fase 0 (4cb9238)

## Fase 1 — Tier 1 ✅
- [x] pan, delay/delaytime/delayfeedback, euclid(k,n[,rot]), `*` `!` `@`, setcps/setcpm, n+scale
- [x] Build demo congelada: tag `demo-freeze-v1` + dist/DemoStrudel-demo-freeze-v1.dmg
- [x] Commit Fase 1 (3c10099)

## Fase 2 — Tier 3 ✅
- [x] rev, ply, every, sometimes/often/rarely (PRNG con seed), off, jux, struct
- [x] Commit Fase 2 (e38ab84)

## Fase 3 — Tier 2 ✅
- [x] sound() sine/sawtooth/square/triangle (polyBLEP), ADSR, lpf/hpf+resonance, speed
- [x] Commit Fase 3 (3cf085d)

## Fase 4 — Tier 4 ✅
- [x] shape/distort, crush (bitcrusher), chop/striate (granular), vowel (formantes)
- [x] chorus/phaser: FUERA a propósito (sin LFO nativo no hay versión honesta; documentado en COMPATIBILITY.md)
- [x] Commit Fase 4

## Fixes (fixes.md) ✅
- [x] Banco de percusión compartido: bd/sd/hh/oh/cp/rim/lt/mt/ht/cr/rd (tidal-drum-machines, CC) en Samples/ + bancos tr909/ y tr808/
- [x] Registrados en ambos motores (mismos archivos, verificado por hash y sonda)
- [x] `bank("tr909")` en Mini Engine (Strudel lo trae nativo)
- [x] Alias `dec`/`att`/`sus`/`rel` + ADSR sobre samples (por evento) + números `.4`
- [x] `$:` patrones paralelos (con `_$:` muted)
- [x] Criterio de aceptación: patrones de fixes.md parsean y cargan en ambos lados (243 tests; WebProbe sin fallos)

## Transversal ✅
- [x] COMPATIBILITY.md al día (Fases 0–4)
- [x] Clean-room respetado; oracle solo como caja negra (45 fixtures, 128 haps)
- [x] 218 tests en verde
