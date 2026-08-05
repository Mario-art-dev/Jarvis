#!/usr/bin/env bash
# Arregla el servidor de Jarvis en Macs que no pueden actualizarse a macOS 13+
# (ej. un iMac 2014 con Big Sur), donde el binario "claude" que trae
# @anthropic-ai/claude-agent-sdk falla con "dyld: Symbol not found".
#
# Instala una versión antigua de @anthropic-ai/claude-code (sin binario nativo,
# pura JS), la deja fija con DISABLE_AUTOUPDATER para que no se autoactualice a
# una versión nueva que vuelva a traer el binario incompatible, y escribe la
# ruta correcta en server/.env — leyendo el nombre real del ejecutable desde el
# package.json instalado en vez de asumir "cli.js", porque ese nombre cambia
# entre versiones (cli.js / cli-wrapper.cjs / bin/claude.exe, según la versión).
#
# Uso: server/scripts/fix-legacy-claude-code.sh [version]
# (version por defecto: 2.1.112, la última que se sabe compatible con Big Sur)

set -euo pipefail

VERSION="${1:-2.1.112}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SERVER_DIR/.env"

echo "==> Instalando @anthropic-ai/claude-code@$VERSION (forzando la versión, sin autoactualizar todavía)..."
npm install -g "@anthropic-ai/claude-code@$VERSION" --force

NPM_ROOT="$(npm root -g)"
PKG_DIR="$NPM_ROOT/@anthropic-ai/claude-code"
PKG_JSON="$PKG_DIR/package.json"

if [ ! -f "$PKG_JSON" ]; then
  echo "ERROR: no encuentro $PKG_JSON tras la instalación." >&2
  exit 1
fi

INSTALLED_VERSION="$(node -e "console.log(require('$PKG_JSON').version)")"
BIN_RELATIVE="$(node -e "
const pkg = require('$PKG_JSON');
const bin = typeof pkg.bin === 'string' ? pkg.bin : pkg.bin.claude || Object.values(pkg.bin)[0];
console.log(bin);
")"
EXECUTABLE_PATH="$PKG_DIR/$BIN_RELATIVE"

if [ ! -f "$EXECUTABLE_PATH" ]; then
  echo "ERROR: el ejecutable esperado no existe: $EXECUTABLE_PATH" >&2
  exit 1
fi

echo "==> Instalado @anthropic-ai/claude-code@$INSTALLED_VERSION"
echo "==> Ejecutable resuelto: $EXECUTABLE_PATH"

if [ ! -f "$ENV_FILE" ]; then
  echo "==> No existe $ENV_FILE, lo creo a partir de .env.example"
  cp "$SERVER_DIR/.env.example" "$ENV_FILE"
fi

set_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # macOS (BSD sed) necesita el '' tras -i; funciona igual en GNU sed.
    sed -i '' -E "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

set_env_var "CLAUDE_CODE_EXECUTABLE_PATH" "$EXECUTABLE_PATH"
set_env_var "DISABLE_AUTOUPDATER" "1"

echo "==> $ENV_FILE actualizado:"
echo "      CLAUDE_CODE_EXECUTABLE_PATH=$EXECUTABLE_PATH"
echo "      DISABLE_AUTOUPDATER=1"
echo ""
echo "Reinicia el servidor (Ctrl+C y luego 'npm start' dentro de server/) para aplicar el cambio."
