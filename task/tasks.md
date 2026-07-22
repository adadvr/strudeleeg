# Tareas — Mini Engine grado producción (newchanges.md)

Plan derivado de [newchanges.md](../newchanges.md). La demo A/B ([devstrudeleeg.md](../devstrudeleeg.md)) está completa; queda su verificación de oído por Adad. Borrar este archivo al terminar todo.

## Pendiente de la demo (manual, Adad)
- [ ] Verificar de oído: código semilla suena igual en ambos lados (fixes de silencio ya aplicados)
- [ ] Probar el .dmg en otra Mac offline

## Fase 0 — Fundación (no negociable, primero)
- [ ] Motor movido a su propio Swift package aislado (`MiniEngine/`), licenciable por separado
- [ ] Core `Pattern<T> = (TimeSpan) -> [Hap<T>]` con tiempo racional
- [ ] Parámetros como patrones (control maps): `.gain("<0.3 0.8>")` funciona
- [ ] Soporte de comentarios `//` en el código del editor
- [ ] Oracle harness: node genera fixtures JSON desde Strudel real; swift test compara
- [ ] Subset existente migrado al nuevo core (stack, s, note, slow, fast, gain, room, cutoff, secuencia, `[]`, `<>`, `~`) con tests en verde
- [ ] La app demo sigue compilando y sonando igual
- [ ] Commit Fase 0

## Fase 1 — Tier 1 (demo-critical; al final se congela build)
- [ ] `pan(x)` nativo
- [ ] `delay` / `delaytime` / `delayfeedback` (AVAudioUnitDelay)
- [ ] `euclid(k,n)` (Bjorklund)
- [ ] Mini-notación `*` `!` `@`
- [ ] `setcps` / `setcpm`
- [ ] `n("0 2 4")` + `scale("C:minor")`
- [ ] Congelar build demo (tag + dmg) para la presentación del jefe
- [ ] Commit Fase 1

## Fase 2 — Tier 3: álgebra de patrones
- [ ] `rev`, `ply(n)`
- [ ] `every(n, f)`
- [ ] `sometimes` / `often` / `rarely` (RNG con seed)
- [ ] `off(t, f)`, `jux(f)`, `struct("t ~ t t")`
- [ ] Commit Fase 2

## Fase 3 — Tier 2: synths
- [ ] `sound("sawtooth/square/sine/triangle")` (AVAudioSourceNode)
- [ ] `attack`/`decay`/`sustain`/`release` (ADSR)
- [ ] `lpf`/`hpf` + `resonance`
- [ ] `speed(x)` (varispeed)
- [ ] Commit Fase 3

## Fase 4 — Tier 4: texturas / DSP custom
- [ ] `shape` / `distort` (AVAudioUnitDistortion)
- [ ] `chorus` / `phaser`
- [ ] `chop(n)` / `striate(n)` (granular)
- [ ] `crush(n)` (bitcrusher)
- [ ] `vowel` (formantes)
- [ ] Commit Fase 4

## Transversal
- [ ] Doc viva `COMPATIBILITY.md` (función → estado → equivalencia Strudel), actualizada por fase
- [ ] Clean-room: nunca leer el código .js de Strudel; oracle = comparar salidas
- [ ] Ciclo por función: implementar → test oracle → commit
