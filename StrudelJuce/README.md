# StrudelJuce — motor de audio JUCE (columna `[juce]`)

Tercer backend de audio de strudeleeg, en C++/JUCE 8. Reutiliza el motor de
patrones Swift de `MiniEngine` (parser + scheduling); esta lib solo recibe eventos
ya calculados y los suena con `juce::dsp`.

## Build (macOS)

```bash
bash StrudelJuce/scripts/build_macos.sh
```

Genera `StrudelJuce/StrudelJuce.xcframework`, consumido por `Package.swift` vía
`binaryTarget`. El módulo Swift importable es `StrudelJuceC` (definido en el
`module.modulemap` empaquetado).

- Primer build: JUCE 8.0.4 se descarga con FetchContent (~300 MB, cacheado en
  `build/_deps/`). Para usar una copia local: `-DJUCE_SOURCE_DIR=/ruta/a/JUCE`.
- El script combina `libStrudelJuce.a` + los módulos JUCE en una sola estática
  con `libtool` y la empaqueta con `xcodebuild -create-xcframework`.

## Arquitectura

```
MiniEngine (Swift)  →  AudioBackend: JUCE  →  C API strudel_*  →  StrudelEngine (C++/juce::dsp)
```

- `include/StrudelJuceCAPI.h` — superficie C pura, **agnóstica de plataforma**.
- `src/StrudelEngine.{h,cpp}` — `juce::AudioIODeviceCallback` (mismo patrón que
  `EnoAudioEngine`), voces + FX.
- `src/StrudelJuceCAPI.cpp` — shim `extern "C"` que castea el handle opaco.

## Migración a iOS (preparado, no activado)

El código NO requiere cambios para iOS. Solo build + sesión de audio:

1. **Compilar el slice iOS** con el toolchain ya presente en `cmake/ios-cmake/`:
   ```bash
   cmake -S StrudelJuce -B StrudelJuce/build/ios-arm64 \
     -DCMAKE_TOOLCHAIN_FILE=StrudelJuce/cmake/ios-cmake/ios.toolchain.cmake \
     -DPLATFORM=OS64 -DDEPLOYMENT_TARGET=14.0
   cmake --build StrudelJuce/build/ios-arm64 --config Release
   ```
   Combinar sus `.a` (igual que `build_macos.sh`) y añadir el slice al mismo
   xcframework con un segundo `-library` en `xcodebuild -create-xcframework`.

2. **`Package.swift`**: añadir `.iOS(.v14)` a `platforms` (o crear un `.xcodeproj`
   mínimo para el target iOS). El `binaryTarget` xcframework ya soporta ambos slices.

3. **AVAudioSession** (solo iOS): antes de `strudel_engine_start`, configurar la
   sesión en categoría `.playback` con la opción que evita que JUCE la pise —
   patrón `configureForJUCEPlayback()` de
   `enoapp2026/ios/EnoApp/.../AudioSessionConfigurationManager.swift`. El define
   `JUCE_DISABLE_AUDIO_MIXING_WITH_OTHER_APPS=1` ya está activo en el CMake.

Nada de lo anterior toca el C API ni el backend: sin re-arquitectura.
