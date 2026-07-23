# Tarea — Funciones faltantes en el Mini Engine (priorizadas)

> **Contexto:** el brief original de tiers estaba incompleto. Cubría meditación + electrónica básica, pero omitió funciones fundamentales para producción musical real. El motor actual (~50 funciones) cubre bien *un estilo*, no producción general. Esta tarea cierra los huecos importantes.

---

## P0 — Críticas (cambio arquitectónico, hacer primero)

Estas no son "una función más": requieren cambios en el modelo de eventos. Si se hacen después, hay que reescribir lo construido encima.

### 1. Acordes — notas simultáneas con coma
```
n("[0,2,4]")            // acorde por grados
note("[a3,c4,e4]")      // acorde por nombres
n("<[0,2,4] [3,5,7]>")  // acordes alternando por ciclo
```
- Un paso de la mini-notación puede contener **varias notas simultáneas** separadas por coma.
- Requiere que el parser emita **N haps en el mismo tiempo** y que el scheduler dispare N voces a la vez.
- **Sin esto no hay armonía, solo melodías monofónicas.** Es lo más grave de la lista para que suene a música.

### 2. Señales continuas — `signal()` y osciladores de control
```
.lpf(sine.range(200, 2000))     // curva suave, no saltos
.gain(signal(() => valor))       // callback externo
```
- Implementar: `signal(fn)`, y los osciladores de control `sine`, `saw`, `tri`, `square`, `rand`, `perlin`, con `.range(min,max)` y `.slow(n)`.
- Hoy los parámetros solo son patroneables vía mini-notación (`"<0.3 0.8>"`), que son **saltos discretos**. Las señales continuas son **curvas suaves**.
- **Esta es la infraestructura del EEG**: un feature del cerebro modula un parámetro como señal continua, sin brincos audibles. Es la función de mayor palanca de todo el documento para Eno.

### 3. Efectos por evento (quitar el "per-chain compromise")
- Hoy documentado en COMPATIBILITY: *"last-set value wins per layer"* — todos los eventos de una capa comparten el mismo lpf/room/vowel/shape.
- Se necesita que **cada evento** pueda tener sus propios valores de efecto.
- Implica cadena de efectos por voz (o pool de cadenas), no por capa.

### 4. `orbit(n)` — buses de efectos separados
```
.orbit(1)  // drums
.orbit(2)  // bass
```
- Rutea capas a cadenas de efectos independientes. Relacionado con el punto 3.
- Prerequisito para `duck` (sidechain).

---

## P1 — Importantes para que suene a electrónica real

### 5. Sidechain / ducking
```
.duck(2).duckattack(0.1).duckdepth(1)
```
- Una capa agacha el volumen de la orbit indicada. Es el "bombeo" característico de techno/house.
- Sin esto la mezcla suena plana.

### 6. `lpenv` — envolvente de filtro
```
.lpf(700).lpq(8).lpenv(2)
```
- El filtro se abre/cierra siguiendo la envolvente ADSR. **Este es el sonido acid.**
- Sin él, un saw con lpf estático suena muerto.
- Añadir también `hpenv` por simetría.

### 7. `add()` — aritmética de patrones
```
.add(note("[0, 0.12]"))   // detune (engorda el sonido)
.add(note("12"))          // transposición de octava
```
- Suma valores a un patrón. Muy usado para detune y transposición.

### 8. Parámetros que faltan
| Función | Nota |
|---|---|
| `postgain(x)` | Ganancia **post-efectos** (distinta de `gain`, que es pre) |
| `size(x)` | Tamaño de la sala del reverb (hoy solo hay `room` = wet) |
| `lpq(x)` | Q del filtro low-pass. Ya existe `resonance` — verificar si es alias o difiere |
| `bank("nombre")` | Selección de banco de samples (ver tarea del banco de samples) |

### 9. Alias cortos de Strudel
`dec`→`decay`, `att`→`attack`, `sus`→`sustain`, `rel`→`release`, `fb`→`delayfeedback`, `dt`→`delaytime`

### 10. `$:` — patrones múltiples
Sintaxis de Strudel para declarar varios patrones independientes en un mismo bloque.

---

## P2 — Funciones de patrón que amplían expresividad

No críticas, pero muy usadas en composición real:

| Función | Qué hace |
|---|---|
| `arp("up"\|"down"\|"updown")` | Arpegia un acorde (requiere P0-1) |
| `superimpose(f)` | Capa extra transformada, sin desfase (a diferencia de `off`) |
| `stut(n, fb, t)` | Repeticiones con decaimiento (eco rítmico) |
| `echo(n, t, fb)` | Similar a stut, otra parametrización |
| `iter(n)` | Rota el patrón un paso por ciclo |
| `chunk(n, f)` | Aplica f a una porción distinta del patrón cada ciclo |
| `palindrome` | Alterna normal / invertido por ciclo |
| `segment(n)` | Discretiza una señal continua en n pasos |
| `range(min,max)` | Escala una señal a un rango (usar con P0-2) |
| `hurry(n)` | Como `fast` pero también sube el pitch |
| `swingBy(x, n)` | Swing / groove |
| Mini `?` | Omisión aleatoria de pasos |
| Mini `{a b, c d e}` | Polimetro |
| `slice(n, i)` / `loopAt(n)` | Trabajo con samples largos / breakbeats |

---

## Orden recomendado

1. **P0-1 (acordes)** y **P0-2 (señales continuas)** — sin estas dos, nada más importa. La primera da armonía; la segunda es el gancho del EEG.
2. **P0-3 y P0-4** (efectos por evento + orbit) — habilitan mezcla real.
3. **P1** completo — es lo que separa "suena a demo" de "suena a producción".
4. **P2** incremental, según haga falta.

## Reglas (sin cambio)

- **Clean-room:** implementar desde la documentación pública (strudel.cc/learn), **nunca** leyendo el código fuente `.js` de Strudel.
- **Oracle de tests:** para cada función, capturar el JSON de eventos del Strudel real y verificar que el motor los reproduce.
- RNG siempre con seed.
- Actualizar `COMPATIBILITY.md` con cada función añadida.