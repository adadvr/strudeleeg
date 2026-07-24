#!/usr/bin/env bash
# fetch_soundfonts.sh — Descarga instrumentos GM a Sources/DemoStrudelApp/Soundfonts/
#
# Uso:
#   bash scripts/fetch_soundfonts.sh            # set curado (~26 instrumentos)
#   bash scripts/fetch_soundfonts.sh all        # los 128 GM (0..127)
#   bash scripts/fetch_soundfonts.sh 0 4 40     # programas específicos
#
# Fuente: https://felixroos.github.io/webaudiofontdata/sound/
# Formato: {XXXX}_FluidR3_GM_sf2_file.js  donde XXXX = printf "%04d" $((program*10))
#
# El directorio destino se crea si no existe.
# Los archivos ya descargados se saltean (idempotente).
# Requiere: curl, bc (para tamaño total).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${REPO_ROOT}/Sources/DemoStrudelApp/Soundfonts"
BASE_URL="https://felixroos.github.io/webaudiofontdata/sound"

# Set curado por defecto: pianos, epianos, vibráfono, marimba, órganos,
# guitarras, bajos, cuerdas, ensemble, coro, flauta, lead, pads, sitar.
DEFAULT_PROGRAMS=(0 1 4 5 11 12 16 19 24 25 27 32 33 35 40 42 48 49 52 73 80 88 89 90 91 104)

# ---------------------------------------------------------------------------
# Determinar qué programas descargar
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    PROGRAMS=("${DEFAULT_PROGRAMS[@]}")
elif [ "$1" = "all" ]; then
    PROGRAMS=()
    for i in $(seq 0 127); do
        PROGRAMS+=("$i")
    done
else
    PROGRAMS=("$@")
fi

# ---------------------------------------------------------------------------
# Crear directorio destino si no existe
# ---------------------------------------------------------------------------
mkdir -p "$DEST_DIR"

echo "==> fetch_soundfonts.sh"
echo "    Destino : ${DEST_DIR}"
echo "    Programas: ${#PROGRAMS[@]}"
echo ""

# ---------------------------------------------------------------------------
# Descargar
# ---------------------------------------------------------------------------
DOWNLOADED=0
SKIPPED=0
FAILED=0

for program in "${PROGRAMS[@]}"; do
    # Validar que sea número 0-127
    if ! [[ "$program" =~ ^[0-9]+$ ]] || [ "$program" -lt 0 ] || [ "$program" -gt 127 ]; then
        echo "    [!] Programa inválido '$program' — debe ser 0-127. Saltando."
        FAILED=$((FAILED + 1))
        continue
    fi

    FILE="sf_${program}.js"
    DEST="${DEST_DIR}/${FILE}"

    # Idempotente: saltar si ya existe
    if [ -f "$DEST" ]; then
        echo "    [ok] Programa $program → ya existe (${FILE})"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Construir URL: XXXX = program * 10 con padding a 4 dígitos
    ID=$(printf "%04d" $((program * 10)))
    URL="${BASE_URL}/${ID}_FluidR3_GM_sf2_file.js"

    echo -n "    [-]  Programa $program → descargando ${FILE} ... "
    if curl -fsSL --retry 3 --retry-delay 1 -o "$DEST" "$URL"; then
        SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
        echo "OK (${SIZE})"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "ERROR (se eliminará archivo parcial si existe)"
        rm -f "$DEST"
        FAILED=$((FAILED + 1))
    fi
done

# ---------------------------------------------------------------------------
# Reporte final
# ---------------------------------------------------------------------------
echo ""
echo "==> Resultado"
echo "    Descargados : ${DOWNLOADED}"
echo "    Ya existían : ${SKIPPED}"
echo "    Errores     : ${FAILED}"

# Tamaño total del directorio
if command -v du &>/dev/null; then
    TOTAL_SIZE=$(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)
    FILE_COUNT=$(find "$DEST_DIR" -name "sf_*.js" | wc -l | tr -d ' ')
    echo "    Archivos JS : ${FILE_COUNT}"
    echo "    Tamaño dir  : ${TOTAL_SIZE}"
fi

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "    ADVERTENCIA: ${FAILED} programa(s) fallaron. Reintentá más tarde."
    exit 1
fi
echo "==> Listo. Directorio listo para incluir en el bundle SPM."
