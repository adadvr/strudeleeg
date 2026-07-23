# Tarea — Funciones para composición real + validador de patrones

> **Origen:** análisis de canciones reales del ecosistema Strudel (`eefano/strudel-songs-collection`, curado en `terryds/awesome-strudel`). Esta lista **no es teórica** — es lo que usan las canciones completas que suenan bien.
>
> **Objetivo:** que el Mini Engine pueda producir música de calidad real, no solo demos.

---

## P0 — Validador de patrones (hacer PRIMERO)

Antes de agregar funciones, el motor necesita **decir claramente qué no soporta**.

### Requisitos
- API: `validate(code) -> [Diagnóstico]` donde cada diagnóstico trae: función/sintaxis no soportada, posición en el texto, y sugerencia de alternativa si existe.
- Se ejecuta **antes** de reproducir. Nunca crashear: reportar y seguir.
- En la UI del panel Mini Engine: mostrar los diagnósticos de forma legible ("`pickOut` no soportado — usa `<>` para alternar secciones").
- Distinguir tres casos: **soportado**, **no soportado**, **JavaScript arbitrario** (ver nota al final).

### Por qué es P0
Sin esto, cualquier código que falle parece un bug del motor. Con esto, queda claro que es una función fuera del subset — y se sabe exactamente cuál pedir.

---

## P1 — Soundfonts GM (mayor impacto sonoro)

```
s("gm_acoustic_guitar_steel:1")
s("gm_string_ensemble_1")
s("gm_pizzicato_strings:1")
s("gm_epiano1")
```

- Instrumentos reales multi-sample (guitarra, cuerdas, piano, etc.). **Esta es la vía para sonidos realistas** — no los osciladores.
- Strudel los carga desde el paquete `@strudel/soundfonts`.
- Implementación: cargar bancos soundfont (SF2/sfz o el set pre-convertido de Strudel) desde el servidor remoto, igual que los samples. Mapeo de nota → sample más cercano + repitch.
- El `:n` selecciona variación, igual que en los samples.

---

## P2 — Estructura de canción (lo que permite piezas largas)

Sin esto no se pueden armar canciones con secciones; solo loops.

| Función | Semántica |
|---|---|
| `pick(patrónÍndice, [pat0, pat1, ...])` | Selecciona qué patrón suena según un índice patroneado |
| `pickOut(...)` | Variante: no reinicia el patrón elegido |
| `pickRestart(...)` | Variante: reinicia el patrón elegido al cambiar |
| `layer(f1, f2, ...)` | Aplica varias transformaciones **en paralelo** al mismo patrón (apila los resultados) |
| Patrones etiquetados `nombre:` | `gtr: ...`, `vox: ...`, `drm: ...` — declarar varias voces con nombre (equivale a `$:` con etiqueta) |

`pick` + `@` (pesos) es **la técnica estándar** para estructurar canciones completas: un patrón índice largo elige qué sección suena en cada compás.

---

## P3 — Expresión y timing (lo que hace que no suene robótico)

| Función | Semántica |
|---|---|
| `clip(x)` | Recorta/extiende la duración de la nota (staccato ↔ legato). Muy usado |
| `late(x)` / `early(x)` | Desplaza el evento en el tiempo (groove, humanización). Ej: `.late(1/64)` |
| `transpose(n)` | Transpone n semitonos |
| `velocity(x)` | Intensidad de la nota (distinta de `gain`) |
| Mini-notación `a/4` | Operador **slow** dentro del string. Ya existe `*`, falta `/` |

---

## P4 — Sistema de acordes

```
chord("<Am E Dm G>").anchor("g5").voicing()
```

| Función | Semántica |
|---|---|
| `chord("Am")` | Acorde por nombre (Am, E7, Dmaj7, G7, sus4, dim…) |
| `voicing()` | Genera la disposición de notas del acorde automáticamente |
| `anchor("g5")` | Registro de referencia para el voicing |

Esto permite escribir progresiones armónicas por nombre en vez de listar cada nota a mano. Requiere que los acordes con coma (P0-1 de la tarea anterior) ya funcionen.

---

## Orden recomendado

1. **P0 (validador)** — quita el riesgo de "código que no funciona".
2. **P1 (soundfonts)** — el salto de calidad sonora más grande por unidad de esfuerzo.
3. **P2 (estructura)** — habilita canciones largas con secciones, no loops.
4. **P3 (expresión)** — quita el sonido robótico.
5. **P4 (acordes)** — comodidad de escritura armónica.

---

## Criterio de aceptación

Una composición de referencia de 3+ minutos debe poder escribirse y sonar bien usando **solo** funciones soportadas, con:
- Al menos un instrumento GM realista (P1).
- Estructura de al menos 4 secciones distintas vía `pick` (P2).
- Groove audible vía `clip` / `late` (P3).

Y el validador debe reportar correctamente un patrón que use funciones fuera del subset.

---

## Nota importante sobre el techo de la arquitectura

Las canciones reales de Strudel **no son solo patrones: son programas de JavaScript**. Usan `const`, objetos, arrow functions, `register()` para definir funciones propias, y APIs internas del motor (`fmap`, `innerJoin`, `withValue`, `pat.pick`).

Ejemplo real:
```js
const gString = register('gString', (n, pat) =>
  (pat.fmap((v) => { ... }).innerJoin()));
```

El Mini Engine es un **parser de mini-notación + scheduler**, no un intérprete de JavaScript. Por más funciones que se agreguen, **no ejecutará código JS arbitrario**. Ese es el techo real de la arquitectura.

**Consecuencia práctica:** el objetivo no es "correr cualquier código de Strudel de internet" (imposible), sino **cubrir un subset expresivo suficiente para componer música de calidad**. El validador (P0) es lo que hace explícito ese límite en vez de que aparezca como un fallo sorpresa.

Documentar el subset soportado en `COMPATIBILITY.md` como **especificación del motor**, no como lista de carencias.

---

## Reglas (sin cambio)

- **Clean-room:** implementar desde documentación pública (strudel.cc/learn), **nunca** leyendo el código fuente `.js` de Strudel.
- **Oracle de tests:** capturar el JSON de eventos del Strudel real y verificar que el motor los reproduce.
- RNG con seed.
- Actualizar `COMPATIBILITY.md` con cada función añadida.