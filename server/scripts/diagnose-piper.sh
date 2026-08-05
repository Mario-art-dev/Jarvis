#!/usr/bin/env bash
# Recoge de una vez todo lo que hace falta saber para entender por qué Piper
# no arranca, en vez de ir probando arreglos a ciegas.
#
# Uso: server/scripts/diagnose-piper.sh
# Copia y pega toda la salida.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/piper"
PIPER_BIN="$PIPER_DIR/piper/piper"

echo "=== macOS ==="
sw_vers 2>/dev/null
uname -m

echo ""
echo "=== ¿Existe el binario? ==="
ls -la "$PIPER_BIN" 2>&1

echo ""
echo "=== Contenido de la carpeta de Piper ==="
ls -la "$PIPER_DIR/piper" 2>&1 | head -30

echo ""
echo "=== ¿Están las librerías .dylib? ==="
find "$PIPER_DIR" -name "*.dylib" 2>/dev/null | head -20
echo "(si no aparece ninguna, el problema es que no se descargaron)"

echo ""
echo "=== Librerías que pide el binario ==="
otool -L "$PIPER_BIN" 2>&1 | head -20

echo ""
echo "=== Rutas de búsqueda grabadas en el binario (rpath) ==="
otool -l "$PIPER_BIN" 2>/dev/null | grep -A2 LC_RPATH | grep "path " || echo "(ninguna)"

echo ""
echo "=== ¿Está install_name_tool disponible? ==="
if command -v install_name_tool >/dev/null 2>&1; then
  echo "sí: $(command -v install_name_tool)"
else
  echo "NO — hacen falta las herramientas de Xcode: xcode-select --install"
fi

echo ""
echo "=== Intento de arranque, con el error completo ==="
cd "$PIPER_DIR/piper" 2>/dev/null && echo "hola" | ./piper --help 2>&1 | head -15
