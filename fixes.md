# Tarea — Cargar el banco de samples compartido

> **Bloqueante.** Sin esto el A/B no es válido: hoy se están comparando dos motores que ambos están mudos de percusión.

## Problema

La carpeta `Samples/` solo contiene `pad.wav` y `bell.wav`. Ni Strudel (WebView) ni el Mini Engine pueden tocar patrones de música electrónica — a los dos les falta el mismo material. No es un bug de código, es contenido faltante.

**Requisito clave:** ambos motores deben leer **exactamente los mismos archivos**. El A/B solo es válido si el banco es idéntico en los dos lados.

---

## 1. Descargar samples de batería

Bajar el set de baterías de Strudel/Tidal (repo `tidalcycles/dirt-samples` o `tidalcycles/tidal-drum-machines`, licencia CC — **los mismos archivos que usa strudel.cc**, para que la comparación sea justa).

Incluir como mínimo, con estos nombres:

`bd`, `sd`, `hh`, `oh`, `cp`, `rim`, `lt`, `mt`, `ht`, `cr`, `rd`

Colocarlos en la carpeta `Samples/` compartida del bundle. **Conservar** el `pad` y `bell` actuales.

## 2. Registrarlos en el lado Strudel (WebView)

En el `index.html`, registrar todos los samples nuevos con `samples({...}, baseUrl)` apuntando a la ruta local, igual que se hizo con pad/bell.

Verificar que `webView.loadFileURL(..., allowingReadAccessTo:)` cubra la carpeta completa.

## 3. Registrarlos en el Mini Engine

Cargar los mismos archivos en el banco del motor nativo, con los mismos nombres.

## 4. Implementar lo que falta

- **`bank("nombre")`** — selección de banco/carpeta de samples (ej. `bank("tr909")`). Si se implementa, organizar los samples en subcarpetas por máquina.
- **Alias cortos de Strudel que faltan:** `dec` → `decay`, `att` → `attack`, `sus` → `sustain`, `rel` → `release`.
- **`$:`** — sintaxis de patrones múltiples de Strudel. Si es fácil, implementarlo; si no, documentarlo como no soportado.

---

## 5. Criterio de aceptación

**No dar la tarea por terminada** hasta confirmar que ambos motores producen sonido de percusión y que los archivos que tocan son los mismos.

Estos patrones deben sonar —y sonar igual— en **ambos** lados:

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

## 6. Actualizar `COMPATIBILITY.md`

Documentar: samples disponibles, alias nuevos, y el estado de `bank()` y `$:`.