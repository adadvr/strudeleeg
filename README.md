# DemoStrudel — Comparativa A/B: Strudel (WebView) vs Motor Nativo Swift

## ¿Qué es esto?

Esta demo permite comparar **dos motores de audio** con el mismo código de meditación, para decidir cuál implementar:

- **Lado izquierdo — Strudel (WebView · WebAudio):** usa el intérprete real de Strudel corriendo dentro de un WebView. Lo mismo que corre en strudel.cc, pero embebido en la app, sin internet.
- **Lado derecho — Mini Engine (Swift · AVAudioEngine):** un motor nativo escrito en Swift desde cero (clean-room, sin reutilizar código de Strudel), usando los frameworks de audio de Apple.

Ambos lados leen los **mismos archivos WAV** (pad y campana) y arrancan con el **mismo código semilla**, así que de fábrica deben sonar igual. La diferencia es el motor por debajo.

---

## Cómo abrirlo

1. Descarga el archivo `DemoStrudel.dmg`.
2. Haz doble clic en el `.dmg` y arrastra `DemoStrudel.app` a la carpeta **Aplicaciones** (o a donde quieras).
3. **Primera vez:** macOS bloqueará la app porque no está notarizada. Haz **clic derecho → Abrir** y confirma en el diálogo. Esto solo ocurre la primera vez.

> **Nota Gatekeeper:** la app está firmada con el Developer ID de Moonshot.la LLC (963B3Q33V9), pero no está notarizada (la notarización requiere subir a los servidores de Apple, paso que no es necesario para esta demo interna). El clic derecho → Abrir es suficiente.

**Requisito:** macOS 14 (Sonoma) o superior. Corre completamente **offline** — no necesita internet.

---

## Cómo usarla

La ventana muestra **dos paneles lado a lado**, cada uno con su editor de código y su botón Play:

```
┌──────────────────────────────┬──────────────────────────────┐
│  Strudel (WebView · WebAudio)│  Mini Engine (Swift · AVAudio)│
│  [editor de código]          │  [editor de código]           │
│         [ ▶ Play ]           │         [ ▶ Play ]            │
└──────────────────────────────┴──────────────────────────────┘
                      [ ■ Stop ]
```

- **Play izquierdo:** inicia el motor Strudel con el código del editor izquierdo.
- **Play derecho:** inicia el motor nativo Swift con el código del editor derecho.
- Al dar Play en un lado, el otro se detiene automáticamente (para una comparación limpia).
- **Stop:** detiene ambos motores.
- El botón Play del lado que está sonando aparece resaltado con un punto indicador "Sonando".
- **Edición en vivo:** puedes cambiar el código en cualquier editor y al dar Play de nuevo se interpreta el texto actualizado.

---

## El código semilla (arranca en ambos lados)

```
stack(
  s("pad").slow(4).gain(0.5).room(0.6),
  note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
)
```

- **`pad`:** un drone/pad en loop, con gain al 50% y reverb al 60%.
- **`bell`:** melodía de campana que alterna entre C4, E4, G4 y B4 cada ciclo, a la mitad de velocidad, con un filtro pasa-bajas a 1500 Hz, reverb al 40% y volumen al 70%.

---

## Qué soporta el lado derecho (Motor Nativo)

El Mini Engine soporta únicamente el subset necesario para meditación:

`stack`, `s`, `note`, `slow`, `fast`, alternancia `<...>`, secuencias `[...]`, `gain`, `room`, `cutoff`

Si el código del editor derecho usa una función fuera de este subset, el motor avisará con un mensaje amable en lugar de fallar.

---

## Nota de expectativas

Con el mismo código, los **patrones y los samples son idénticos** entre las dos versiones. La única diferencia posible está en el **acabado de los efectos** (la cola del reverb, la curva del filtro), porque el Motor B usa el DSP nativo de Apple y el Motor A el de Web Audio. Para meditación esa diferencia es prácticamente imperceptible. Si se percibe algo, es cerrable portando ese efecto con más detalle — no es una limitación del enfoque.

---

## Ficha técnica (para quien quiera saber más)

- **Plataforma:** macOS 14+ (SwiftUI + Swift Package Manager)
- **Motor A:** Strudel real (strudel.cc) embebido como bundle JS offline en WKWebView. Audio: Web Audio API del sistema.
- **Motor B:** Parser y scheduler escritos desde cero en Swift; audio con AVAudioEngine, AVAudioPlayerNode, AVAudioUnitEQ y AVAudioUnitReverb.
- **Samples:** archivos WAV autocontenidos dentro del .app. Funciona sin internet.
- **Firma:** Developer ID Application: Moonshot.la LLC (963B3Q33V9). Sin notarización (demo interna).
