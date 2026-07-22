# Brief de agente — Mini Engine (Swift): motor de patrones Strudel-compatible, grado producción

> Extiende el Mini Engine de la demo A/B hacia un motor completo y **reusable en producción**. Todos los tiers (efectos + patrones + synths). Se construye a grado producción, no como demo desechable.

---

## Contexto y decisión

- El Mini Engine ya toca el subset básico de meditación y suena ~99% igual a Strudel. Esto lo **extiende** hacia un motor Strudel-compatible completo.
- Si el jefe elige la vía nativa, **este es el motor de producción de Eno.** Por eso se construye con arquitectura correcta y tests, no con hacks de demo.
- La **build de demo A/B no se rompe** en ninguna fase: se congela una build estable tras la Fase 1 para la presentación al jefe.

---

## Reglas NO negociables

1. **Clean-room, siempre.** Cada función se implementa **desde la documentación pública** (strudel.cc/learn, papers de Tidal Cycles) y comparando *salidas observables*. **NUNCA** leyendo ni traduciendo el código fuente `.js` de Strudel. Si esta versión llega a producción, no puede contener obra derivada de AGPL.
2. **Oracle de tests.** Para cada función: capturar el JSON de eventos que emite el Strudel real para patrones de prueba, y el motor debe **reproducir esos eventos**. Es la red de seguridad Y la prueba objetiva de "suena/se comporta igual". Comparar salidas ≠ copiar código → clean-room-safe.
3. **Determinismo.** Todo RNG con **seed** (reproducibilidad, defensa clínica para Eno, y tests estables).
4. **Aislamiento.** El motor vive en su propio Swift package, licenciable por separado, sin enredarse con el código que embebe Strudel (WebView).

---

## Fase 0 — Fundación (hacer ANTES de cualquier tier)

Esta es la fase que hace que todo lo demás sea posible y reusable. Es un refactor del core actual.

### Modelo de patrón genérico
Un patrón es una **función del tiempo → eventos**. Concretamente:
```
Pattern<T> = (TimeSpan) -> [Hap<T>]
```
### Parámetros como patrones (la clave)
Cada parámetro (`gain`, `cutoff`, `pan`, …) **no es un escalar fijo** — es a su vez un `Pattern<Double>` evaluable en el tiempo. El scheduler consulta cada parámetro **en el tiempo del evento**.

Esto habilita de un solo golpe:
- **Efectos patroneables** — `.gain("<0.3 0.8>")`, `.cutoff(sine.range(200,2000))`.
- **El gancho del EEG** — un feature del cerebro es solo otra señal que modula un parámetro. Misma maquinaria.

> Si esto se hace después, hay que reescribir el scheduler. Se hace ahora. No es opcional.

### Entregables Fase 0
- Core refactorizado a `Pattern<T>` + parámetros como patrones.
- Oracle test harness montado y corriendo.
- Todo lo que YA suena (stack, s, note, slow, fast, gain, room, cutoff + mini-notación secuencia / `[]` / `<>` / `~`) migrado al nuevo core, con tests en verde.

---

## Fase 1 — Tier 1: alto impacto, bajo costo (demo-critical)

Con esto la pieza ya suena producida y rítmica. **Al terminar esta fase se congela la build para la demo del jefe.**

| Función | Semántica | Implementación |
|---|---|---|
| `pan(x)` | posición estéreo | 🟢 nativo |
| `delay` / `delaytime` / `delayfeedback` | eco | 🟢 `AVAudioUnitDelay` |
| `euclid(k,n)` | ritmos euclidianos (Bjorklund) | 🟡 lógica de patrón |
| mini-notación `*` `!` `@` | repetir / replicar / alargar pasos | 🟢 extender parser |
| `setcps` / `setcpm` | tempo global (cps/BPM) | 🟢 |
| `n("0 2 4")` + `scale("C:minor")` | melodía por grados de escala | 🟡 |

---

## Fase 2 — Tier 3: álgebra de patrones (barato, mucha variación)

Lo que evita que suene en loop muerto. Barato porque es lógica de patrón, no DSP.

| Función | Semántica | Impl. |
|---|---|---|
| `rev` | invierte el patrón | 🟢 |
| `ply(n)` | repite cada evento n veces (rolls) | 🟢 |
| `every(n, f)` | aplica transformación cada n ciclos | 🟡 |
| `sometimes` / `often` / `rarely` | aplica f con probabilidad (RNG con seed) | 🟡 |
| `off(t, f)` | copia desfasada (eco melódico / canon) | 🟡 |
| `jux(f)` | separa estéreo y aplica f a un canal | 🟡 |
| `struct("t ~ t t")` | rítmica booleana sobre un sonido | 🟡 |

> Los **efectos patroneables** (`.gain("<...>")`, `.cutoff(sine.range(...))`) ya funcionan gratis gracias a la Fase 0.

---

## Fase 3 — Tier 2: synths (el salto a electrónica)

⚠️ **Decisión de producto, no solo técnica:** los synths amplían el target de *meditación* (lo que pidió el jefe) a *música general / electrónica*. Válido, pero consciente.

| Función | Semántica | Impl. |
|---|---|---|
| `sound("sawtooth/square/sine/triangle")` | osciladores como fuente sonora | 🔴 `AVAudioSourceNode` con osciladores |
| `attack`/`decay`/`sustain`/`release` | envolvente ADSR de amplitud | 🟡 |
| `lpf`/`hpf` + `resonance` | filtros con resonancia (acid/wob) | 🟡 |
| `speed(x)` | repitch / velocidad del sample | 🟢 varispeed |

---

## Fase 4 — Tier 4: texturas / DSP custom (lo más caro, al final)

| Función | Semántica | Impl. |
|---|---|---|
| `shape` / `distort` | saturación | 🟢 `AVAudioUnitDistortion` |
| `chorus` / `phaser` | modulación | 🟡🔴 |
| `chop(n)` / `striate(n)` | corte granular del sample | 🔴 granular custom |
| `crush(n)` | bitcrusher (lo-fi) | 🔴 DSP custom |
| `vowel` | filtro de formantes (voz) | 🔴 DSP custom |

---

## Modelo de audio (referencia)

- `s()` / `note()` → `AVAudioUnitSampler` (repitch nativo) o `AVAudioPlayerNode` + varispeed.
- Cadena de efectos por voz/capa: `AVAudioUnitEQ` (cutoff, lpf/hpf), `AVAudioUnitReverb` (room), `AVAudioUnitDelay` (delay), pan en el mixer, `AVAudioUnitDistortion` (shape).
- Synths (Fase 3): `AVAudioSourceNode` generando osciladores.
- Parámetros patroneables: el scheduler evalúa el `Pattern<Double>` de cada parámetro en el tiempo del evento y aplica el valor (ramp para continuos).

---

## Reglas de trabajo

- Ciclo por función: **implementar → test contra oracle → commit**. Nada se da por bueno sin su test.
- No romper la build de demo en ninguna fase.
- Todo RNG con seed.
- Motor en package aislado; construido solo desde documentación.
- Reporte a Adad al cierre de cada fase.

---

## Entregables

1. Swift package del motor, aislado y con licencia propia.
2. Suite de tests oracle (patrón → eventos esperados).
3. **Build de demo congelada tras Fase 1** para la presentación del jefe.
4. Doc viva de funciones soportadas (tabla función → estado → equivalencia con Strudel).

---

## Orden recomendado y por qué

Fase 0 (fundación) → Fase 1 (demo-critical, se congela build) → Fase 2 (variación barata) → Fase 3 (synths, decisión de producto) → Fase 4 (DSP caro).

La Fase 0 primero **no es negociable**: sin el modelo de parámetros patroneables, las Fases 2–4 y el EEG requieren reescribir el core. Con ella, todo lo demás es incremental sobre la misma base.