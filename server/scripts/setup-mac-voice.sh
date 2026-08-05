#!/usr/bin/env bash
# Elige la voz del propio Mac que usará Jarvis. Gratis, ilimitada, sin cuenta
# ni internet: viene dentro de macOS, no hay nada que descargar.
#
# Uso:
#   server/scripts/setup-mac-voice.sh --list      # ver las voces en español instaladas
#   server/scripts/setup-mac-voice.sh             # probar y fijar la mejor disponible
#   server/scripts/setup-mac-voice.sh Jorge       # probar y fijar esa voz
#   server/scripts/setup-mac-voice.sh --auto      # volver a la elección automática
#
# Si no haces nada, Jarvis ya elige solo la mejor voz en español que tengas.
# Este script solo sirve para escucharlas y quedarte con la que más te guste.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SERVER_DIR/.env"

if [ "$(uname)" != "Darwin" ]; then
  echo "ERROR: esto solo funciona en un Mac." >&2
  exit 1
fi

# say -v ? imprime "Nombre   es_ES   # frase de ejemplo". Los nombres pueden
# llevar espacios, así que nos anclamos al código de idioma.
spanish_voices() {
  say -v '?' | sed -n 's/^\(.*[^ ]\)  *\(es[_-][A-Z][A-Z]\) *#.*/\1|\2/p'
}

# tr solo toca los bytes ASCII, así que los acentos (2 bytes en UTF-8) pasan
# intactos: "Mónica" -> "mónica", que es justo lo que queremos comparar.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# "Jorge (Mejorada)" -> "Jorge", para que pedir "Jorge" valga para cualquiera
# de sus versiones.
base_name() { printf '%s' "${1%% (*}"; }

# Cuanto más bajo, mejor calidad. macOS puede listar la versión mejorada de
# una voz como una entrada aparte, y es la que interesa.
quality_rank() {
  case "$(lower "$1")" in
    *premium*) echo 0 ;;
    *mejorada*|*enhanced*) echo 1 ;;
    *) echo 2 ;;
  esac
}

# Sexo de las voces en español de macOS, para que la lista sea útil de un
# vistazo. Si sale una que no conozco, simplemente no se anota.
voice_gender() {
  case "$(lower "$(base_name "$1")")" in
    jorge|juan|diego|carlos|enrique) echo "hombre" ;;
    mónica|monica|marisol|paulina|angelica|angélica|soledad|isabela) echo "mujer" ;;
    *) echo "" ;;
  esac
}

show_upgrade_hint() {
  cat <<'EOF'

¿Suena robótica? Hay versiones "mejoradas" de estas mismas voces que suenan
muchísimo mejor, son gratis y las descarga el propio macOS:

  Preferencias del Sistema > Accesibilidad > Contenido hablado
  > Voz del sistema > Personalizar...
  > marca la voz en español que ponga "(Mejorada)" o "(Premium)" y Aceptar

Tarda unos minutos en descargarse. Cuando termine, vuelve a ejecutar este
script: se llaman igual, así que Jarvis usará la mejorada automáticamente.
EOF
}

VOICES="$(spanish_voices || true)"

if [ -z "$VOICES" ]; then
  echo "Este Mac no tiene ninguna voz en español instalada."
  echo ""
  echo "Añádela en: Preferencias del Sistema > Accesibilidad > Contenido hablado"
  echo "> Voz del sistema > Personalizar... > busca 'Español' y marca una (Mónica, Jorge...)"
  echo ""
  echo "Mientras tanto Jarvis sigue funcionando con ElevenLabs y con la voz del iPhone."
  exit 1
fi

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
  echo "Voces en español instaladas en este Mac:"
  echo ""
  while IFS='|' read -r name locale; do
    gender="$(voice_gender "$name")"
    [ -n "$gender" ] && gender="($gender)"
    printf "  %-24s %-8s %s\n" "$name" "$locale" "$gender"
  done <<< "$VOICES"
  echo ""
  echo "Para escuchar una y dejarla fija:  ./scripts/setup-mac-voice.sh \"Jorge\""
  echo "Si tienes la versión mejorada de una voz, basta con poner el nombre a"
  echo "secas: se coge la mejor versión que haya."
  show_upgrade_hint
  exit 0
fi

set_env_var() {
  local key="$1" value="$2"
  [ -f "$ENV_FILE" ] || cp "$SERVER_DIR/.env.example" "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # El nombre de la voz puede llevar acentos y espacios; | como separador de
    # sed evita chocar con las barras de las rutas del resto del fichero.
    sed -i '' -E "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

if [ "${1:-}" = "--auto" ]; then
  if [ -f "$ENV_FILE" ]; then
    sed -i '' -E '/^MAC_VOICE=/d' "$ENV_FILE"
  fi
  echo "Listo: Jarvis vuelve a elegir sola la mejor voz en español que tengas."
  echo "Reinicia el servidor (Ctrl+C y 'npm start' dentro de server/)."
  exit 0
fi

REQUESTED="${1:-}"
if [ -z "$REQUESTED" ]; then
  REQUESTED="$(head -1 <<< "$VOICES" | cut -d'|' -f1)"
  echo "==> No has dicho ninguna, pruebo con \"$REQUESTED\"."
fi

# Se compara sin distinguir mayúsculas y admitiendo el nombre a secas
# ("Jorge" vale para "Jorge (Mejorada)"), pero lo que se guarda es el nombre
# tal cual lo escribe macOS: `say -v` sí distingue. Entre varias versiones de
# la misma voz gana la de mejor calidad.
MATCHED=""
MATCHED_RANK=9
while IFS='|' read -r name locale; do
  if [ "$(lower "$name")" = "$(lower "$REQUESTED")" ] ||
     [ "$(lower "$(base_name "$name")")" = "$(lower "$(base_name "$REQUESTED")")" ]; then
    rank="$(quality_rank "$name")"
    if [ "$rank" -lt "$MATCHED_RANK" ]; then
      MATCHED="$name"
      MATCHED_RANK="$rank"
    fi
  fi
done <<< "$VOICES"

if [ -z "$MATCHED" ]; then
  echo "ERROR: no tienes instalada una voz en español llamada \"$REQUESTED\"." >&2
  echo "" >&2
  echo "Las que sí tienes:" >&2
  cut -d'|' -f1 <<< "$VOICES" | sed 's/^/  /' >&2
  echo "" >&2
  echo "No se ha cambiado nada." >&2
  exit 1
fi
if [ "$MATCHED" != "$REQUESTED" ]; then
  echo "==> Uso \"$MATCHED\", que es la mejor versión que tienes de esa voz."
fi
REQUESTED="$MATCHED"

echo "==> Escucha cómo suena..."
say -v "$REQUESTED" -r 185 "Buenas señor, ¿en qué puedo ayudarle?"

# La prueba de verdad no es que suene por el altavoz, sino que sepa escribir
# el WAV de 16 bits que el iPhone puede reproducir.
TEST_WAV="$(mktemp -t jarvis-say).wav"
if ! say -v "$REQUESTED" -r 185 -o "$TEST_WAV" --data-format=LEI16@22050 "Prueba." 2>/tmp/jarvis-say-error.txt || [ ! -s "$TEST_WAV" ]; then
  echo "" >&2
  echo "ERROR: esa voz suena pero no puede generar el audio que necesita el móvil." >&2
  cat /tmp/jarvis-say-error.txt >&2
  echo "No se ha cambiado nada." >&2
  rm -f "$TEST_WAV"
  exit 1
fi
echo "==> Audio generado correctamente ($(wc -c < "$TEST_WAV" | tr -d ' ') bytes)."
rm -f "$TEST_WAV"

set_env_var "MAC_VOICE" "$REQUESTED"

echo ""
echo "==> Listo. Jarvis hablará con \"$REQUESTED\"."
echo "    Reinicia el servidor (Ctrl+C y 'npm start' dentro de server/)."
echo "    Al arrancar deberías leer: 'Voz: la del propio Mac, \"$REQUESTED\"'."
show_upgrade_hint
