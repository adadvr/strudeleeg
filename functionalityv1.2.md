# Tarea — Carga de samples por URL (servidor remoto), no bundleados

> **Bloqueante.** Hoy `Samples/` solo tiene `pad.wav` y `bell.wav`, así que las composiciones reales quedan mudas en **ambos** motores.
>
> **Decisión de arquitectura:** los samples **NO se bundlean** en la app. Se cargan **desde una URL remota** (servidor DigitalOcean / Spaces). Así se pueden agregar samples nuevos subiéndolos al servidor, sin recompilar ni redistribuir la app.
>
> **Requisito clave:** ambos motores (Strudel WebView y Mini Engine) deben cargar **exactamente los mismos archivos desde la misma URL**. El A/B no es válido si los bancos difieren.

---

## 1. Estructura del banco en el servidor

Definir una URL base configurable, ej:
```
https://<bucket>.<region>.digitaloceanspaces.com/samples/
```

Estructura esperada (misma convención que dirt-samples): una carpeta por nombre de sample, con N variaciones dentro.

```
samples/
  strudel.json         ← manifest (índice del banco)
  bd/  bd_0.wav  bd_1.wav ...
  sd/  sd_0.wav ...
  hh/  oh/  cp/  rim/
  tabla/  hand/  bongo/
  sitar/  pluck/  arpy/
  wind/  birds/  padlong/
```

### Manifest `strudel.json`
Formato compatible con el que Strudel ya entiende:
```json
{
  "_base": "https://<bucket>.../samples/",
  "bd":    ["bd/bd_0.wav", "bd/bd_1.wav"],
  "tabla": ["tabla/tabla_0.wav", "tabla/tabla_1.wav", "tabla/tabla_2.wav"],
  "sitar": ["sitar/sitar_0.wav"]
}
```
El manifest es la **fuente de verdad** del banco: agregar un sample = subir el archivo + actualizar el JSON. Cero cambios en la app.

### Contenido mínimo a subir al servidor
Tomarlos de `tidalcycles/dirt-samples` (licencia CC — mismos archivos que usa strudel.cc, para que el A/B sea justo). Prioridad, que es lo que usan las composiciones actuales:

- **Percusión electrónica:** `bd`, `sd`, `hh`, `oh`, `cp`, `rim`, `lt`, `mt`, `ht`, `cr`, `rd`
- **Percusión ancestral:** `tabla`, `hand`, `bongo`, `drum`
- **Melódicos:** `sitar`, `pluck`, `arpy`, `bell`, `casio`
- **Ambiente:** `wind`, `birds`, `padlong`

---

## 2. Configuración de la URL base

- La URL base debe ser **configurable** (no hardcodeada): archivo de config, Info.plist o variable de entorno.
- Debe poder apuntarse a otro servidor sin recompilar la lógica del motor.
- Fallback opcional: si el manifest remoto no responde, usar los `pad`/`bell` locales para que la app no quede muda.

---

## 3. Implementar `samples()` en el Mini Engine

```
samples('https://<bucket>.../samples/strudel.json')
samples({ mysound: 'ruta/archivo.wav' }, baseUrl)
```

- Descargar y parsear el manifest → registrar el banco en memoria.
- Descarga **perezosa**: bajar el archivo de audio solo cuando un patrón lo usa por primera vez, no todo el banco de golpe.
- Decodificar a `AVAudioPCMBuffer` vía `AVAudioFile` / `AVAudioFormat`.

### Caché local en disco (imprescindible)
- Guardar cada sample descargado en `Caches/` con clave por ruta relativa.
- Antes de descargar: revisar caché. **Sin esto, cada play vuelve a bajar todo por red.**
- Caché persistente entre lanzamientos de la app.

### Carga asíncrona sin trabar el audio
- La descarga es asíncrona; **nunca** bloquear el audio thread ni la UI esperando red.
- Si un sample aún no está listo cuando le toca sonar: saltar ese evento (silencio) y loguearlo, sin crashear ni glitchear el motor.
- Prefetch: al evaluar un patrón, disparar la descarga de todos los samples que menciona antes de arrancar la reproducción.

---

## 4. Lado Strudel (WebView)

- En el `index.html`, llamar `samples('https://<bucket>.../samples/strudel.json')` con **la misma URL base** que el Mini Engine.
- **CORS:** el bucket/servidor debe enviar `Access-Control-Allow-Origin` permitiendo el origen del WebView, o el navegador bloquea las descargas. Este es el punto de falla más común — verificarlo temprano.
- Si el WebView carga vía `file://`, confirmar que las peticiones remotas no las bloquee la política de seguridad; ajustar `WKWebViewConfiguration` si hace falta.

---

## 5. Implementar selección de variación `:n`

```
s("tabla:0 tabla:3 tabla:5")
s("bd:2")
```
- Cada nombre del manifest tiene un array de variaciones; `nombre:n` selecciona el índice n (base 0).
- Sin índice (`s("tabla")`) → variación 0.
- Índice fuera de rango → módulo sobre la cantidad disponible (comportamiento de Strudel).

## 6. Implementar `bank()`

```
s("bd hh sd").bank("tr909")
```
- Selecciona banco/subcarpeta de samples (máquinas de ritmo: `tr909`, `tr808`, `tr707`).
- Requiere subir también `tidalcycles/tidal-drum-machines` al servidor, organizado por máquina, e indexado en el manifest.

## 7. Samples melódicos con `note()`

```
note("g#4 c#5 e5").s("sitar")
```
- El motor ya repitcha `pad`/`bell`; verificar que la misma lógica de varispeed funcione con **cualquier** sample del banco remoto.
- Documentar la **nota base** asumida para el repitch (¿C4? ¿C3?) y verificarla contra el oracle de Strudel — si no coincide, la melodía suena transportada respecto a Strudel.

---

## 8. Criterio de aceptación

**No dar la tarea por terminada** hasta que estos patrones suenen —y suenen igual— en **ambos** lados, con los samples viniendo del servidor:

```
s("[bd <hh oh>]*2").bank("tr909").dec(.4)
```

```
stack(
  s("bd*4").dec(0.4).gain(0.95),
  s("~ cp ~ cp").gain(0.5),
  s("[hh <hh oh>]*4").dec(0.25).gain(0.35)
)
```

```
stack(
  s("tabla:0 ~ ~ tabla:3 ~ ~ tabla:1 ~").gain(0.35),
  s("wind").gain(0.12).room(0.9),
  note("g#4 ~ a4 g#4").s("sitar").gain(0.4).room(0.45)
)
```

Verificar además:
- Ambos motores cargan de **la misma URL** y tocan **los mismos archivos** (no basta con que ambos hagan ruido).
- Segundo play **no** vuelve a descargar (la caché funciona).
- Agregar un sample nuevo al servidor + manifest lo hace disponible **sin recompilar**.

---

## 9. Actualizar `COMPATIBILITY.md`

Documentar: URL base configurada, formato del manifest, cómo agregar samples nuevos, estado de `samples()` / `bank()` / `:n`, nota base del repitch, y comportamiento de caché.

---

## Notas

1. **Esto no resuelve los acordes con coma** (`[g#3 c#4 e4]`) — es la tarea P0-1 de funciones faltantes, aparte. Las composiciones con arpegios seguirán sin funcionar en el Mini Engine hasta implementarla.

2. **Implicación para producción (fuera de alcance de esta tarea, pero a tener presente):** cargar samples por red significa que la app **depende de conexión** la primera vez que usa cada sonido. Para EnoApp en iOS con background/sleep mode, eso es un riesgo — ahí conviene precargar y cachear el set completo antes de iniciar la sesión, o bundlear un set mínimo. Para la demo en Mac no es problema.