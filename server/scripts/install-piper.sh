#!/usr/bin/env bash
# Instala Piper (voz local, gratis e ilimitada) y una voz en español, y deja
# server/.env configurado para usarlo.
#
# Es completamente opcional: si algo falla aquí, Jarvis sigue funcionando
# exactamente igual que antes (ElevenLabs y, si se agotan los créditos, la
# voz del propio iPhone). Nada de lo que hagas aquí puede dejarlo mudo.
#
# Uso: server/scripts/install-piper.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPER_DIR="$SERVER_DIR/piper"
ENV_FILE="$SERVER_DIR/.env"

# Voz española de calidad media: buen equilibrio entre naturalidad y
# velocidad en un Mac antiguo. Hay más en:
# https://huggingface.co/rhasspy/piper-voices/tree/main/es/es_ES
VOICE_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/davefx/medium"
VOICE_ONNX="es_ES-davefx-medium.onnx"

case "$(uname -m)" in
  arm64) PIPER_ASSET="piper_macos_aarch64.tar.gz" ;;
  x86_64) PIPER_ASSET="piper_macos_x64.tar.gz" ;;
  *) echo "ERROR: arquitectura $(uname -m) no soportada por Piper." >&2; exit 1 ;;
esac

echo "==> Descargando Piper ($PIPER_ASSET)..."
mkdir -p "$PIPER_DIR"
cd "$PIPER_DIR"
curl -L --fail --progress-bar \
  "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/$PIPER_ASSET" \
  -o piper.tar.gz
tar -xzf piper.tar.gz
rm -f piper.tar.gz

PIPER_BIN="$PIPER_DIR/piper/piper"
if [ ! -x "$PIPER_BIN" ]; then
  echo "ERROR: no encuentro el ejecutable en $PIPER_BIN tras descomprimir." >&2
  exit 1
fi

echo "==> Descargando la voz en español ($VOICE_ONNX)..."
curl -L --fail --progress-bar "$VOICE_BASE/$VOICE_ONNX" -o "$PIPER_DIR/$VOICE_ONNX"
# El .json va al lado del .onnx y describe el modelo; Piper lo busca solo.
curl -L --fail --progress-bar "$VOICE_BASE/$VOICE_ONNX.json" -o "$PIPER_DIR/$VOICE_ONNX.json"

echo "==> Comprobando que Piper arranca en este Mac..."
# macOS pone en cuarentena lo descargado; sin esto el binario no abre.
xattr -dr com.apple.quarantine "$PIPER_DIR" 2>/dev/null || true

TEST_WAV="$(mktemp -t jarvis-piper).wav"
if ! echo "Hola, soy Jarvis." | "$PIPER_BIN" --model "$PIPER_DIR/$VOICE_ONNX" --output_file "$TEST_WAV" 2>/tmp/piper-test-error.txt; then
  echo ""
  echo "ERROR: Piper no arranca en este Mac. Detalle:" >&2
  cat /tmp/piper-test-error.txt >&2
  echo ""
  echo "Suele pasar en macOS antiguos, donde el binario precompilado pide una"
  echo "versión más nueva del sistema. No se ha cambiado nada: Jarvis sigue"
  echo "usando ElevenLabs y la voz del iPhone como hasta ahora."
  rm -f "$TEST_WAV"
  exit 1
fi
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
