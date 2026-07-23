# Tareas — Mini Engine grado producción

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

# (histórico) Tareas — newchanges.md

Plan derivado de [newchanges.md](../newchanges.md). La demo A/B ([devstrudeleeg.md](../devstrudeleeg.md)) está completa; queda su verificación de oído por Adad. Borrar este archivo al terminar todo.

## Pendiente de la demo (manual, Adad)
- [ ] Verificar de oído: código semilla suena igual en ambos lados (fixes de silencio ya aplicados)
- [ ] Probar el .dmg en otra Mac offline

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
