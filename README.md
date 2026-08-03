# Jarvis — asistente de voz personal para iPhone

App iOS (SwiftUI) con interfaz HUD, reconocimiento de voz, un "cerebro"
que corre **Claude Code autenticado con tu suscripción de Claude** (no una
API key de pago por uso), y respuestas habladas con una voz de ElevenLabs.
Puede abrir apps, buscar en internet, y leer/crear eventos, recordatorios y
contactos con tu permiso.

## Qué es realmente posible en iOS (léelo antes de nada)

Pediste "acceso máximo posible a todo el móvil". En Android eso incluiría
control profundo del sistema; en **iOS, sin jailbreak, Apple no lo permite a
ninguna app**, por diseño (sandboxing). Esta app te da el máximo real dentro
de esas reglas:

**Sí incluido:**
- Escuchar y transcribir tu voz, y responder con audio generado por ElevenLabs.
- Decidir qué hacer usando Claude Code como cerebro (tool-calling / function calling), corriendo en un servidor tuyo con tu suscripción.
- Abrir apps concretas con URL scheme público: Mapas, Mail, Mensajes, Teléfono, FaceTime, Cámara, Calendario, Recordatorios, Ajustes, WhatsApp, Spotify, Instagram, TikTok, YouTube, Gmail, Chrome, Teams, App Store, Música, Notas, Notas de voz, Archivos. No es una lista abierta: cada una está programada a mano y hay un tope técnico de 50 apps declarables en total. Apps sin URL scheme público (Calculadora, Tiempo, Traductor, la app de Claude, la de ChatGPT...) no se pueden abrir así.
- Abrir búsquedas en Safari.
- Leer y crear eventos de Calendario y Recordatorios (con tu permiso, vía EventKit).
- Buscar contactos por nombre (vía Contacts framework).
- Contar/buscar fotos en tu galería por fecha, favoritas o capturas (vía Photos framework), y también por *contenido* ("fotos de perros", "fotos de la playa") usando el clasificador de imágenes de Apple (Vision), corriendo en el propio iPhone sin internet. Solo analiza tus fotos más recientes (hasta 120) para que sea rápido, no toda la galería.
- Consultar el tiempo real (temperatura, viento, humedad) de cualquier lugar del mundo, sin API key, corriendo en el servidor.
- Buscar y leer la web de verdad (no solo abrir una búsqueda) usando WebSearch/WebFetch, para preguntas que necesiten información actual de internet.
- Reproducir una playlist tuya de la app Música por nombre, con reproducción aleatoria opcional (vía MediaPlayer, solo playlists que ya tengas guardadas en tu biblioteca).
- Decirte cuántos correos sin leer tienes en Gmail y sus remitentes/asuntos, vía IMAP con una contraseña de aplicación de Google (sin OAuth, sin proyecto de Google Cloud). Configúralo en `server/.env` con `GMAIL_ADDRESS`/`GMAIL_APP_PASSWORD` — genera la contraseña en https://myaccount.google.com/apppasswords (requiere verificación en dos pasos activada). Solo lectura de asunto/remitente, nunca modifica nada ni lee el cuerpo completo del correo.

**No incluido, y por qué:**
- Leer WhatsApp/Instagram/apps bancarias por dentro, o "controlar" otra app como si fueras tú: iOS no expone eso a ninguna app de terceros, jailbreak included solo con muchísimo riesgo de seguridad — no lo vamos a hacer.
- "Hey Jarvis" en segundo plano de forma indefinida: el reconocimiento de voz de Apple no puede correr sin fin en background. La app usa manos-libres tipo "pulsa para hablar". Si quieres wake-word real, se añade con un motor de terceros (p.ej. Picovoice Porcupine) — es un paso aparte.
- Leer resultados de una búsqueda web: Jarvis puede *abrir* Safari con la búsqueda ya hecha, pero no puede leer lo que hay en la pantalla de otra app.

## Arquitectura

Dos partes que hablan por WebSocket:

```
                  ws:// (misma red / Tailscale)
 [ iPhone: app Jarvis ] <────────────────────> [ server/: Node + Claude Code ]
   - HUD, mic, ElevenLabs                         - autenticado con TU suscripción
   - ejecuta las tools (Fotos,                     - decide qué tool llamar
     Calendario, abrir apps...)                    - nunca ejecuta nada él mismo
```

El servidor **nunca** ejecuta las acciones directamente — solo decide qué
hacer. Cada "tool" (buscar en la web, abrir una app, leer el calendario...)
se ejecuta siempre en el iPhone, con los permisos normales de iOS, y el
resultado vuelve al servidor para que Claude siga la conversación. Así
aprovechas tu suscripción de Claude Code en vez de pagar la API por token,
a cambio de tener que dejar un ordenador encendido con el servidor corriendo.

```
Sources/JarvisApp/                    (la app del iPhone)
  JarvisApp.swift              # punto de entrada
  Views/
    HUDView.swift               # interfaz circular tipo la de tu imagen
    ConversationView.swift      # pantalla principal (mic, transcript)
    SettingsView.swift          # servidor + claves de ElevenLabs
  Core/
    Config/
      SecureStore.swift         # Keychain (nunca guardamos claves en texto plano)
      AppConfig.swift
    Voice/
      SpeechRecognizer.swift    # voz -> texto (Speech framework)
      ElevenLabsClient.swift    # texto -> audio
      AudioPlayer.swift
    Brain/
      JarvisServerClient.swift  # WebSocket hacia server/
      ConversationEngine.swift  # orquesta: escuchar -> preguntar al server -> hablar
    Tools/
      ToolProtocol.swift        # contrato + registro de herramientas
      WebSearchTool.swift
      AppLauncherTool.swift
      PhotosTool.swift
      CalendarTool.swift
      RemindersTool.swift
      ContactsTool.swift

server/                               (el "cerebro", corre en tu Mac/PC)
  src/
    index.ts                    # servidor WebSocket + bucle de Claude Code
    jarvisTools.ts               # mismas tools que el iPhone, pero como proxy remoto
```

Cada tool está definida **dos veces** (Swift en el iPhone, TypeScript en el
servidor) porque son plataformas distintas: la definición del servidor solo
describe el nombre/parámetros para que Claude sepa cuándo llamarla; quien
la ejecuta de verdad es siempre el iPhone.

## 1. Crear tu voz en ElevenLabs

1. Crea cuenta en https://elevenlabs.io (tiene plan gratuito limitado).
2. Elige una voz: o clonas la tuya (**Voices → Add Voice → Instant Voice Clone**, subes 1-3 min de audio), o coges una ya hecha de la **Voice Library** (filtrando por género/edad) y le das a "Add to my voices".
3. Entra en esa voz guardada y copia su **Voice ID**.
4. Ve a tu perfil → **API Keys** → **Create API Key**, marca al menos permiso de "Text to Speech", y cópiala — solo se muestra una vez.

## 2. Preparar el servidor (usa tu suscripción de Claude, no una API key de pago)

Necesitas un ordenador que puedas dejar encendido y conectado a internet
mientras uses Jarvis (tu Mac, un Mac mini, un Raspberry Pi con Node, o una
VPS barata). No hace falta que sea el mismo Mac donde compilas la app iOS.

```bash
# 1. Instala Node.js 22+ si no lo tienes (https://nodejs.org)

# 2. Instala el CLI de Claude Code globalmente
npm install -g @anthropic-ai/claude-code

# 3. Inicia sesión con tu cuenta de Claude (Pro/Max) — NO con una API key
claude login
# Elige la opción de iniciar sesión con tu cuenta claude.ai / suscripción.

# 4. Prepara el servidor de Jarvis
cd Jarvis/server
npm install
cp .env.example .env
# Edita .env y pon un token secreto largo en JARVIS_SERVER_TOKEN
# (genera uno con: openssl rand -hex 32)

# 5. Arráncalo
npm start
```

Verás `Jarvis server escuchando en :8787`. Mientras ese proceso esté vivo y
tengas sesión iniciada con `claude login`, el servidor usa tu suscripción
normal de Claude — no se factura por API aparte.

**Averigua la IP de ese ordenador** en tu red local (macOS: Ajustes →
Wi-Fi → Detalles → IP; o `ipconfig getifaddr en0` en Terminal). La usarás en
la app como `ws://TU_IP:8787`.

Si quieres usar Jarvis fuera de casa (no en la misma red), monta algo como
[Tailscale](https://tailscale.com) entre el móvil y el ordenador — así
`ws://` sigue funcionando por la red privada sin exponer el servidor a
internet abierto.

## 3. Conseguir la app en tu iPhone

### Opción A — tienes un Mac

Este repo no incluye un `.xcodeproj` binario (se genera con
[XcodeGen](https://github.com/yonaskolb/XcodeGen) a partir de `project.yml`,
así el proyecto no se corrompe al fusionar cambios en git).

```bash
brew install xcodegen
cd Jarvis
xcodegen generate
open Jarvis.xcodeproj
```

En Xcode:
1. Selecciona el proyecto → target **Jarvis** → pestaña **Signing & Capabilities**.
2. Elige tu **Team** (tu Apple ID gratuito sirve para instalar en tu propio iPhone).
3. Conecta el iPhone por cable (o misma red con Wi-Fi debugging) y selecciónalo como destino.
4. Run (▶). La primera vez, en el iPhone: **Ajustes → General → VPN y gestión de dispositivos → confía en tu certificado de desarrollador.**

Con una cuenta gratuita de Apple Developer la app hay que reinstalarla cada
7 días (límite de Apple). Con cuenta de pago (99$/año) dura 1 año.

### Opción B — no tienes Mac (compila en la nube, instala desde Windows)

El repo incluye `.github/workflows/build-ipa.yml`: cada vez que se sube
código a una rama `claude/**`, GitHub compila automáticamente la app en un
Mac virtual gratuito y deja lista una `.ipa` **sin firmar** para descargar.
Firmarla e instalarla en tu iPhone se hace desde Windows con
[Sideloadly](https://sideloadly.io) y tu Apple ID normal (gratis, sin cuenta
de desarrollador de pago).

1. Ve a **github.com/Mario-art-dev/Jarvis → pestaña Actions → "Build unsigned IPA"**, entra en la ejecución más reciente (✅ verde) y descarga el artefacto **`Jarvis-unsigned-ipa`** (es un .zip; dentro está `Jarvis.ipa`).
2. Instala [Sideloadly](https://sideloadly.io/#get) en tu PC de Windows, y [iTunes/Apple Devices](https://apps.microsoft.com/detail/9np83lwlpz9k) si te lo pide (para que Windows reconozca el iPhone por USB).
3. Conecta el iPhone al PC por cable y desbloquéalo (acepta "Confiar en este ordenador" si te lo pregunta).
4. Abre Sideloadly, arrastra `Jarvis.ipa` a la ventana.
5. En el campo Apple ID, pon tu correo de Apple ID normal (el mismo con el que usas iCloud/App Store). Sideloadly te pedirá la contraseña la primera vez (no la guarda en texto plano, la usa solo para firmar).
6. Dale a **Start**. Tardará un par de minutos firmando e instalando.
7. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos** → toca tu Apple ID → **Confiar**.
8. Abre Jarvis desde la pantalla de inicio.

**Aviso importante:** con Apple ID gratuito, la app deja de abrir a los **7
días** (la firma caduca) — tendrás que repetir los pasos 3-7 con Sideloadly
(no hace falta recompilar si el código no ha cambiado, reutiliza el mismo
`Jarvis.ipa`). Es la única pega real de no tener Mac ni pagar los 99$/año de
Apple Developer.

Cada vez que yo cambie el código de la app, se genera una `.ipa` nueva
automáticamente — vuelve a la pestaña Actions y descarga la más reciente.

## 4. Primer arranque

1. Con el servidor (`npm start`) corriendo, abre la app en el iPhone. Como no hay nada guardado, se abrirá **Ajustes**.
2. Pega:
   - **Server URL**: `ws://TU_IP:8787`
   - **Server Token**: el mismo valor que pusiste en `server/.env`
   - **API key de ElevenLabs** y **Voice ID**
3. Guardar.
4. Pulsa el micrófono, di algo como *"Búscame los mejores restaurantes de Madrid"* o *"Qué tengo hoy en el calendario"*.
5. Jarvis te responderá en voz alta.

La primera vez el iPhone te pedirá permiso de **red local** — acéptalo, es
para poder hablar con tu servidor.

## 5. Activarlo con la voz o con un gesto ("despierta Jarvis")

iOS no deja que ninguna app escuche el micrófono en segundo plano (ni con
jailbreak sensato), así que no existe un "Hey Jarvis" puro. Pero sí hay dos
disparadores nativos de Apple que abren la app y la ponen a escuchar en un
solo paso, usando el esquema `jarvisapp://listen` que ya lleva incorporado:

**A) Con la voz, a través de Siri:**
1. Abre la app **Atajos** (Shortcuts) del iPhone.
2. Pestaña **Automatización** → **+** → **Crear automatización personal**.
3. Elige el disparador que prefieras (por ejemplo **"Aplicación"** no vale para invocar por voz; usa mejor el propio atajo con frase de Siri, ver paso 4).
4. Mejor: pestaña **Mis atajos** → **+** para crear un atajo nuevo → busca la acción **"Abrir URLs"** → pon `jarvisapp://listen` → nombra el atajo, por ejemplo "Despertar Jarvis".
5. Toca los "···" del atajo → **Añadir a Siri** → graba la frase, por ejemplo **"Despierta Jarvis"**.
6. Listo: di **"Oye Siri, despierta Jarvis"** y se abrirá la app ya escuchando.

**B) Con un gesto físico (el equivalente real a "aplaudir dos veces"):**
iOS no detecta aplausos, pero sí un toque doble en la parte trasera del
teléfono (Back Tap), que es más fiable y no depende del ruido ambiente:
1. **Ajustes → Accesibilidad → Tocar → Tocar parte trasera**.
2. Elige **"Doble toque"** (o "Triple toque" si prefieres evitar activaciones sin querer).
3. Baja hasta **Atajos** y selecciona el mismo atajo **"Despertar Jarvis"** que creaste arriba.
4. Ahora, dando dos golpecitos en la parte de atrás del iPhone, se abre Jarvis escuchando — sin pasar por Siri.

## Seguridad

- Las claves de ElevenLabs y el token del servidor se guardan en el
  **Keychain de iOS**, cifradas, nunca en UserDefaults ni en el código.
- El servidor solo acepta conexiones que manden el `Authorization: Bearer
  <JARVIS_SERVER_TOKEN>` correcto — no lo compartas ni lo subas a git
  (`server/.env` ya está en `.gitignore`).
- El servidor tiene **desactivadas** las herramientas normales de Claude
  Code (Bash, editar/leer archivos, etc.) — solo puede llamar a las tools
  de Jarvis, que a su vez solo hacen lo que ves en `Core/Tools/`. No puede
  tocar archivos de tu ordenador ni ejecutar comandos.
- Si alguna vez compartes tu token o tus claves por error, revócalas /
  cámbialas de inmediato.

## Ampliar Jarvis

Para añadir una nueva capacidad hacen falta dos piezas, porque cada lado
ejecuta en una plataforma distinta:
1. Un `struct` en `Core/Tools/` que implemente `JarvisTool` (Swift, ejecuta en el iPhone), registrado en `ToolRegistry.init()`.
2. La misma tool descrita en `server/src/jarvisTools.ts` con `tool(...)`, con el mismo `name` y los mismos parámetros, y añadida a `allowedTools` en `server/src/index.ts`.

Claude la verá automáticamente como una opción más la próxima vez que le
pidas algo relacionado.
