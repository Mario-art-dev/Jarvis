#!/usr/bin/env bash
# Instala Piper (voz local, gratis e ilimitada) y una voz en español, y deja
# server/.env configurado para usarlo.
#
# Es completamente opcional: si algo falla aquí, Jarvis sigue funcionando
# exactamente igual que antes (ElevenLabs y, si se agotan los créditos, la
# voz del propio iPhone). Nada de lo que hagas aquí puede dejarlo mudo.
#
# Uso:
#   server/scripts/install-piper.sh            # voz por defecto (davefx)
#   server/scripts/install-piper.sh --list     # ver todas las voces
#   server/scripts/install-piper.sh sharvard   # instalar/cambiar a esa voz
#
# Cambiar de voz después es solo volver a ejecutarlo con otro nombre: no
# vuelve a descargar Piper, solo la voz nueva.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPER_DIR="$SERVER_DIR/piper"
ENV_FILE="$SERVER_DIR/.env"

# nombre|idioma|carpeta|calidad|descripción
# Catálogo completo: https://huggingface.co/rhasspy/piper-voices/tree/main/es
VOICES=(
  "davefx|es_ES|davefx|medium|Hombre, español de España. Equilibrada y natural (por defecto)"
  "sharvard|es_ES|sharvard|medium|Mujer, español de España. Clara y neutra"
  "carlfm|es_ES|carlfm|x_low|Hombre, español de España. La más rápida, calidad baja"
  "claude|es_MX|claude|high|Mujer, español de México. Calidad alta, la que mejor suena"
  "daniela|es_AR|daniela|high|Mujer, español de Argentina. Calidad alta"
  "ald|es_MX|ald|medium|Hombre, español de México"
)

list_voices() {
  echo "Voces disponibles:"
  echo ""
  for entry in "${VOICES[@]}"; do
    IFS='|' read -r key lang _ quality desc <<< "$entry"
    printf "  %-10s %s\n" "$key" "$desc"
  done
  echo ""
  echo "Para instalar una:  ./scripts/install-piper.sh <nombre>"
  echo "Las de calidad 'high' suenan mejor pero tardan algo más en generarse,"
  echo "lo que en un Mac antiguo puede notarse como un pequeño retraso al hablar."
}

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
  list_voices
  exit 0
fi

REQUESTED="${1:-davefx}"
VOICE_ENTRY=""
for entry in "${VOICES[@]}"; do
  if [ "${entry%%|*}" = "$REQUESTED" ]; then VOICE_ENTRY="$entry"; break; fi
done

if [ -z "$VOICE_ENTRY" ]; then
  echo "ERROR: no conozco la voz \"$REQUESTED\"." >&2
  echo "" >&2
  list_voices >&2
  exit 1
fi

IFS='|' read -r VOICE_KEY VOICE_LANG VOICE_FOLDER VOICE_QUALITY VOICE_DESC <<< "$VOICE_ENTRY"
VOICE_ONNX="${VOICE_LANG}-${VOICE_FOLDER}-${VOICE_QUALITY}.onnx"
VOICE_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/es/${VOICE_LANG}/${VOICE_FOLDER}/${VOICE_QUALITY}"

echo "==> Voz elegida: $VOICE_KEY — $VOICE_DESC"

case "$(uname -m)" in
  arm64) PIPER_ASSET="piper_macos_aarch64.tar.gz" ;;
  x86_64) PIPER_ASSET="piper_macos_x64.tar.gz" ;;
  *) echo "ERROR: arquitectura $(uname -m) no soportada por Piper." >&2; exit 1 ;;
esac

mkdir -p "$PIPER_DIR"
PIPER_BIN="$PIPER_DIR/piper/piper"

if [ -x "$PIPER_BIN" ]; then
  echo "==> Piper ya está instalado, solo descargo la voz."
else
  echo "==> Descargando Piper ($PIPER_ASSET)..."
  cd "$PIPER_DIR"
  curl -L --fail --progress-bar \
    "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/$PIPER_ASSET" \
    -o piper.tar.gz
  tar -xzf piper.tar.gz
  rm -f piper.tar.gz

  if [ ! -x "$PIPER_BIN" ]; then
    echo "ERROR: no encuentro el ejecutable en $PIPER_BIN tras descomprimir." >&2
    exit 1
  fi

  # El paquete de Piper para Mac Intel está roto de origen: trae el ejecutable
  # pero ninguna de las librerías (.dylib) contra las que está enlazado, así
  # que no puede arrancar en ningún Mac. No es un problema de este ordenador y
  # no tiene arreglo desde aquí. Se detecta antes de tocar nada.
  if [ -z "$(find "$PIPER_DIR" -name '*.dylib' -print -quit 2>/dev/null)" ]; then
    echo "" >&2
    echo "ERROR: el paquete de Piper para $(uname -m) que publican sus autores está" >&2
    echo "incompleto: no incluye las librerías que el programa necesita, así que" >&2
    echo "no puede arrancar. No es culpa de tu Mac." >&2
    echo "" >&2
    echo "Usa la voz del propio macOS, que es igual de gratis e ilimitada y ya la" >&2
    echo "tienes instalada:" >&2
    echo "" >&2
    echo "  ./scripts/setup-mac-voice.sh --list" >&2
    echo "" >&2
    echo "No se ha cambiado nada." >&2
    rm -rf "$PIPER_DIR/piper"
    exit 1
  fi
fi

if [ -f "$PIPER_DIR/$VOICE_ONNX" ]; then
  echo "==> Esa voz ya estaba descargada."
else
  echo "==> Descargando la voz ($VOICE_ONNX)..."
  if ! curl -L --fail --progress-bar "$VOICE_BASE/$VOICE_ONNX" -o "$PIPER_DIR/$VOICE_ONNX"; then
    rm -f "$PIPER_DIR/$VOICE_ONNX"
    echo "" >&2
    echo "ERROR: no se pudo descargar la voz desde:" >&2
    echo "  $VOICE_BASE/$VOICE_ONNX" >&2
    echo "" >&2
    echo "Si el enlace da 404, el catálogo puede haber cambiado de sitio." >&2
    echo "Mira los nombres actuales en:" >&2
    echo "  https://huggingface.co/rhasspy/piper-voices/tree/main/es" >&2
    echo "y dime cuál hay, para corregir el script." >&2
    echo "" >&2
    echo "No se ha cambiado nada: Jarvis sigue funcionando como hasta ahora." >&2
    exit 1
  fi
  # El .json va al lado del .onnx y describe el modelo; Piper lo busca solo.
  if ! curl -L --fail --progress-bar "$VOICE_BASE/$VOICE_ONNX.json" -o "$PIPER_DIR/$VOICE_ONNX.json"; then
    rm -f "$PIPER_DIR/$VOICE_ONNX" "$PIPER_DIR/$VOICE_ONNX.json"
    echo "ERROR: la voz se descargó pero falta su archivo .json de configuración." >&2
    exit 1
  fi
fi

echo "==> Comprobando que Piper arranca en este Mac..."
# macOS pone en cuarentena lo descargado; sin esto el binario no abre.
xattr -dr com.apple.quarantine "$PIPER_DIR" 2>/dev/null || true

# El binario busca sus librerías en @rpath, que en las builds de macOS de
# Piper no apunta a ninguna parte útil. Indicárselo con DYLD_LIBRARY_PATH no
# es fiable: la protección de integridad de macOS (SIP) descarta las
# variables DYLD_* en muchos contextos. Grabar @executable_path como rpath
# dentro del propio binario sí es permanente y SIP no puede quitarlo.
PIPER_BIN_DIR="$(dirname "$PIPER_BIN")"
if command -v install_name_tool >/dev/null 2>&1; then
  if ! otool -l "$PIPER_BIN" 2>/dev/null | grep -q "path @executable_path "; then
    echo "==> Grabando la ruta de las librerías dentro del binario..."
    install_name_tool -add_rpath "@executable_path" "$PIPER_BIN" 2>/dev/null || true
    # Cambiar el binario invalida su firma; re-firmarlo localmente evita que
    # macOS lo mate al arrancar.
    codesign --force --sign - "$PIPER_BIN" 2>/dev/null || true
  fi
else
  echo "AVISO: no tienes install_name_tool (viene con las herramientas de" >&2
  echo "línea de comandos de Xcode). Si la prueba falla, instálalas con:" >&2
  echo "  xcode-select --install" >&2
fi

TEST_WAV="$(mktemp -t jarvis-piper).wav"

# DYLD_LIBRARY_PATH además del rpath grabado arriba: en los Macs donde SIP
# no lo descarta, sirve de cinturón y tirantes. Se ejecuta desde su propia
# carpeta para que encuentre también espeak-ng-data.
if ! ( cd "$PIPER_BIN_DIR" && echo "Hola, soy Jarvis." | \
       DYLD_LIBRARY_PATH="$PIPER_BIN_DIR" DYLD_FALLBACK_LIBRARY_PATH="$PIPER_BIN_DIR" \
       "$PIPER_BIN" --model "$PIPER_DIR/$VOICE_ONNX" --output_file "$TEST_WAV" ) 2>/tmp/piper-test-error.txt; then
  echo ""
  echo "ERROR: Piper no arranca en este Mac. Detalle:" >&2
  cat /tmp/piper-test-error.txt >&2
  echo "" >&2
  if grep -q "Symbol not found\|not supported\|minimum.*version" /tmp/piper-test-error.txt; then
    echo "El binario precompilado pide una versión de macOS más nueva que la" >&2
    echo "de este Mac. No hay arreglo sencillo: habría que compilar Piper" >&2
    echo "desde el código fuente." >&2
  else
    echo "Pásame este error y lo miramos — puede tener arreglo." >&2
  fi
  echo "" >&2
  echo "No se ha cambiado nada: Jarvis sigue usando ElevenLabs y la voz del" >&2
  echo "iPhone como hasta ahora." >&2
  rm -f "$TEST_WAV"
  exit 1
fi

# Comprobación de verdad: que el WAV tenga contenido, no solo que el
# proceso saliera con código 0.
if [ ! -s "$TEST_WAV" ]; then
  echo "ERROR: Piper arrancó pero no generó audio. No se ha cambiado nada." >&2
  rm -f "$TEST_WAV"
  exit 1
fi
echo "==> Prueba de voz correcta ($(wc -c < "$TEST_WAV" | tr -d ' ') bytes de audio)."
rm -f "$TEST_WAV"

set_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i '' -E "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

[ -f "$ENV_FILE" ] || cp "$SERVER_DIR/.env.example" "$ENV_FILE"
set_env_var "PIPER_PATH" "$PIPER_BIN"
set_env_var "PIPER_VOICE" "$PIPER_DIR/$VOICE_ONNX"

echo ""
echo "==> Listo. Piper funciona y $ENV_FILE ya apunta a él."
echo "    Reinicia el servidor (Ctrl+C y 'npm start' dentro de server/)."
echo "    Al arrancar deberías leer: 'Voz: Piper (local, ilimitada).'"
