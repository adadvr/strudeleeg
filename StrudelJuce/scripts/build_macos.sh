#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# build_macos.sh — compila StrudelJuce para macOS arm64, combina libStrudelJuce.a
# con todos los modulos JUCE en una sola lib estatica y la empaqueta en
# StrudelJuce.xcframework (con Headers/ + module.modulemap) para consumo SPM.
#
# Uso:  bash StrudelJuce/scripts/build_macos.sh
# Salida: StrudelJuce/StrudelJuce.xcframework
#
# iOS (cuando se active): replicar con el toolchain ios-cmake y añadir el slice
# con `xcodebuild -create-xcframework -library <ios.a> ... `. Ver README.md.
# ----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/macos-arm64"
CONFIG="Release"

echo "==> Configurando CMake (macOS arm64, $CONFIG)"
cmake -S "$ROOT" -B "$BUILD" -G "Ninja" \
    -DCMAKE_BUILD_TYPE="$CONFIG" \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="14.0" 2>/dev/null \
  || cmake -S "$ROOT" -B "$BUILD" \
       -DCMAKE_BUILD_TYPE="$CONFIG" \
       -DCMAKE_OSX_ARCHITECTURES="arm64" \
       -DCMAKE_OSX_DEPLOYMENT_TARGET="14.0"

echo "==> Compilando"
cmake --build "$BUILD" --config "$CONFIG"

# El CMake de JUCE compila los modulos DENTRO de libStrudelJuce.a (interface
# targets que agregan sus fuentes al target consumidor), asi que la lib ya es
# autocontenida. Si en el futuro JUCE se linkea como .a separadas, combinar aqui.
LIB="$BUILD/libStrudelJuce.a"
if [ ! -f "$LIB" ]; then
    # fallback: buscar la lib donde la deje el generador
    LIB="$(find "$BUILD" -name 'libStrudelJuce.a' | head -1)"
fi
if [ -z "$LIB" ] || [ ! -f "$LIB" ]; then
    echo "ERROR: no se encontro libStrudelJuce.a en $BUILD" >&2
    exit 1
fi
COMBINED="$LIB"
echo "==> Lib estatica autocontenida: $COMBINED ($(du -h "$COMBINED" | cut -f1))"

echo "==> Preparando Headers + module.modulemap"
HDR="$BUILD/xcframework-headers"
rm -rf "$HDR"; mkdir -p "$HDR"
cp "$ROOT/include/StrudelJuceCAPI.h" "$HDR/"
cat > "$HDR/module.modulemap" <<'EOF'
module StrudelJuceC {
    header "StrudelJuceCAPI.h"
    export *
}
EOF

echo "==> Empaquetando xcframework"
OUT="$ROOT/StrudelJuce.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$COMBINED" -headers "$HDR" \
    -output "$OUT"

echo "==> Listo: $OUT"
