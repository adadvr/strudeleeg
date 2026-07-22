# Brief de agente — Demo A/B macOS: Strudel (WebView) vs Mini Engine (Swift + AVAudioEngine)

> Para correr con Claude Code. Objetivo: **rápido y funcional**. Es una demo para que el jefe **decida**, no un producto. El entregable final es un **ejecutable (.app / .dmg)** para compartir.

---

## Objetivo

App de escritorio para macOS con **dos editores de código lado a lado** y **dos motores de audio**, para comparar A/B:

- **Izquierda — "Strudel"**: editor con código Strudel real → lo interpreta el **Motor A (Strudel en WKWebView)**.
- **Derecha — "Mini Engine (Swift)"**: editor con código en la misma nomenclatura → lo interpreta el **Motor B (nativo Swift + AVAudioEngine)**.

El jefe escribe/edita en cualquiera de los dos, da play a cada lado, compara, y decide cuál se implementa.

**Piso de aceptación (no negociable):** música básica de meditación **con filtros básicos** (`cutoff`, `room`, `gain`) debe **sonar igual** en ambos lados con el mismo código.

---

## Reglas no negociables

1. **Es demo para decidir, no producto.** Alcance al mínimo. **Hardcodear está permitido.** El Motor B solo tiene que soportar el subset básico de meditación (abajo), no todo Strudel.
2. **Clean-room en el Motor B.** El motor nativo se construye **desde la documentación pública** de la mini-notación (strudel.cc/learn) y comparando *salidas*, **nunca leyendo el código fuente `.js` de Strudel**. Si esta versión gana, se convierte en el código real, así que no puede nacer contaminada de AGPL.
3. **Motor B aislado.** Vive en su propio target/package Swift, separado del código que embebe Strudel.
4. **Comparación justa.** Los dos motores usan **exactamente los mismos archivos WAV**. Ambos editores arrancan con **el mismo código semilla**, así que de fábrica deben sonar igual. La única diferencia debe ser el motor.

---

## Preguntas para Adad antes de arrancar (esperar respuesta)

1. Versión mínima de macOS objetivo (¿14/15?) y ¿tiene Xcode instalado?
2. ¿Tiene cuenta de Apple Developer para firmar el .app, o se comparte sin firmar?
3. Los **samples**: ¿los provee él (2–3 WAV: un pad/drone y una campana/bell), o el agente usa un set libre sugerido? Deben ser apropiados para meditación.
4. Confirmar el **código semilla** (propuesta abajo) o ajustarlo.

---

## Subset de meditación que el Mini Engine DEBE soportar

Solo esto — ni una función más:
`stack`, `s`, `note`, `slow`, `fast`, alternancia `<...>`, secuencia y `[...]`, `gain`, `room`, `cutoff`.

### Código semilla (arranca en AMBOS editores, idéntico)

```
stack(
  s("pad").slow(4).gain(0.5).room(0.6),
  note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
)
```

Con el mismo texto en los dos lados, Strudel (izq) y el Mini Engine (der) deben producir la misma música de meditación. El jefe puede editar cualquiera de los dos y volver a dar play.

---

## Arquitectura

App SwiftUI de una ventana, **layout de dos paneles (izquierda/derecha)**. Un protocolo común y dos implementaciones:

```swift
protocol AudioDemoEngine {
    func play(code: String)   // re-lee el texto ACTUAL del editor
    func stop()
}
```

### Motor A — `StrudelWebEngine` (WKWebView) — panel izquierdo
- Un `WKWebView` carga un `index.html` local que importa `@strudel/web`.
- `play(code:)` → `webView.evaluateJavaScript` con el código actual del editor izquierdo.
- Samples registrados con `samples({ pad:'pad.wav', bell:'bell.wav' }, baseUrl)` apuntando a la carpeta local de WAV bundleada.
- El audio lo hace Strudel (Web Audio). No se reimplementa nada aquí.
- **Riesgo de integración #1 (atacar temprano):** que el WebView pueda leer los WAV locales. Usar `webView.loadFileURL(indexURL, allowingReadAccessTo: resourcesDir)`.

### Motor B — `NativeEngine` (Swift + AVAudioEngine) — panel derecho
- `MiniNotationParser` → `[Event]` (solo el subset de arriba). Cada evento: `{ time, sample, note?, gain, room, cutoff }`.
- `Scheduler` agenda los eventos en la línea de tiempo de `AVAudioEngine`.
- Reproducción:
  - Melodía con pitch (`note` + `s("bell")`) → `AVAudioUnitSampler` (repitcha desde un solo sample) **o** `AVAudioPlayerNode` con rate = `2^((midi-base)/12)`.
  - Drone (`s("pad")`) → `AVAudioPlayerNode` en loop.
- Efectos (constantes por capa, como en el código):
  - `cutoff` → `AVAudioUnitEQ` low-pass.
  - `room` → `AVAudioUnitReverb` (wet = valor).
  - `gain` → volumen del nodo.
- Usa **los mismos WAV** que el Motor A.
- Si el código del editor derecho usa algo fuera del subset → mostrar aviso amable ("función no soportada en la demo"), no crashear.

### Samples compartidos
Una sola carpeta `Samples/` en el bundle (p.ej. `pad.wav`, `bell.wav`). Ambos motores leen de ahí.

### UI (dos paneles con labels)
```
┌───────────────────────────┬───────────────────────────┐
│ Strudel (WebView·WebAudio)│ Mini Engine (Swift·AVAudio)│   ← labels
│ ┌───────────────────────┐ │ ┌───────────────────────┐ │
│ │  [editor de texto]    │ │ │  [editor de texto]    │ │   ← TextEditor
│ │  (código semilla)     │ │ │  (mismo código semilla)│ │
│ └───────────────────────┘ │ └───────────────────────┘ │
│        [ ▶ Play ]         │        [ ▶ Play ]         │   ← play por lado
└───────────────────────────┴───────────────────────────┘
                    [ ■ Stop ]                              ← stop compartido
```
- Cada **Play** re-lee el texto **actual** de su editor (edición en vivo).
- Un solo motor suena a la vez; alternar libremente para el A/B.
- (Opcional, si sobra tiempo) toggle "A/B sync" que arranque los dos alineados al mismo punto.

---

## Fases

**F0 — Scaffold.** Proyecto Xcode/SwiftPM, ventana con los dos paneles vacíos, "hola mundo" de audio: un WAV suena por `AVAudioEngine`.

**F1 — Motor B seco.** Parser del subset + scheduler tocando el código semilla **sin efectos**. Validar timing/secuencia contra el Strudel de referencia (de oído / contra el JSON de eventos de Strudel como oráculo).

**F2 — Motor B efectos.** Agregar `cutoff` (EQ low-pass), `room` (reverb), `gain`. **Aquí se cumple el piso de aceptación.**

**F3 — Motor A.** Strudel en el `WKWebView` interpretando el editor izquierdo, con los mismos samples. Resolver acceso a archivos locales.

**F4 — UI + empaque.** Dos paneles + labels + play por lado + stop, y generar el ejecutable.

Checkpoint tras cada fase: build corriendo + reporte a Adad.

---

## Empaquetar el ejecutable (para compartir con el jefe)

1. Build en Release → `DemoStrudel.app`.
2. Empaquetar como `.dmg` (o `.zip` del `.app`).
3. **Gatekeeper:** si va **sin firmar**, el README debe decir que la primera vez se abre con **clic derecho → Abrir** (o Ajustes → Privacidad y Seguridad). Si Adad tiene cuenta de developer, firmar aunque sea ad-hoc.
4. Verificar que samples + bundle de Strudel quedaron **dentro** del .app (corre en otra Mac, offline, sin dependencias).

---

## Reglas de trabajo

- Swift + SwiftUI. Motor nativo aislado en su propio target.
- **Sin sobre-ingeniería:** sin parser general, sin tests exhaustivos, sin edge cases. Solo el subset de meditación.
- Motor B **desde documentación**, nunca desde el `.js` de Strudel.
- Commits por fase; build tras cada una.

---

## Entregables

1. `DemoStrudel.app` empaquetado en `.dmg` (autocontenido, corre offline).
2. `README.md` con: cómo abrirlo (nota de Gatekeeper), el código usado, y qué está comparando el jefe.
3. El código, con el Motor B en su target aislado.

---

## Nota de expectativas (incluir en el README para el jefe)

Con el mismo código, los **patrones y los samples son idénticos** entre las dos versiones. La única diferencia posible está en el **acabado de los efectos** (la cola del reverb, la curva del filtro), porque el Motor B usa el DSP nativo de Apple y el Motor A el de Web Audio. Para meditación esa diferencia es prácticamente imperceptible. Si se percibe algo, es cerrable portando ese efecto con más detalle — no es una limitación del enfoque.