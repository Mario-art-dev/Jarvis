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
- Abrir apps concretas con URL scheme: Mapas, Google Maps, Mail, Mensajes, Teléfono, FaceTime, Cámara, Calendario, Recordatorios, Ajustes, WhatsApp, Spotify, Instagram, TikTok, YouTube, Gmail, Chrome, Teams, App Store, Música, Notas, Notas de voz, Archivos, ChatGPT, Claude, Netflix, Prime Video, Movistar+, HBO Max, Brawl Stars, Clash Royale, CapCut, Canva, Reloj. No es una lista abierta: cada una está programada a mano y hay un tope técnico de 50 apps declarables en total. Las de Google/Apple/Microsoft (Maps, Gmail, Chrome, Teams...) están documentadas y funcionan seguro; el resto son la mejor apuesta sin poder probarlas en un dispositivo real — si alguna no abre, dínoslo para investigar el enlace correcto. Apps sin ninguna puerta pública conocida (Calculadora, Traductor...) no se pueden abrir así.
- Abrir búsquedas en Safari.
- Leer y crear eventos de Calendario y Recordatorios (con tu permiso, vía EventKit).
- Buscar contactos por nombre (vía Contacts framework).
- Contar/buscar fotos en tu galería por fecha, favoritas o capturas (vía Photos framework), y también por *contenido* ("fotos de perros", "fotos de la playa") usando el clasificador de imágenes de Apple (Vision), corriendo en el propio iPhone sin internet. Solo analiza tus fotos más recientes (hasta 120) para que sea rápido, no toda la galería.
- Consultar el tiempo real (temperatura, viento, humedad) de cualquier lugar del mundo, sin API key, corriendo en el servidor.
- Buscar y leer la web de verdad (no solo abrir una búsqueda) usando WebSearch/WebFetch, para preguntas que necesiten información actual de internet.
- Reproducir una playlist tuya de la app Música por nombre, con reproducción aleatoria opcional (vía MediaPlayer, solo playlists que ya tengas guardadas en tu biblioteca).
- Decirte cuántos correos sin leer tienes en Gmail y sus remitentes/asuntos, vía IMAP con una contraseña de aplicación de Google (sin OAuth, sin proyecto de Google Cloud). Soporta varias cuentas con etiqueta ("personal", "trabajo") — configúralo en `server/.env` con `GMAIL_1_LABEL`/`GMAIL_1_ADDRESS`/`GMAIL_1_APP_PASSWORD` (y `GMAIL_2_...` para una segunda cuenta, etc.) — genera la contraseña en https://myaccount.google.com/apppasswords (requiere verificación en dos pasos activada). Solo lectura de asunto/remitente, nunca modifica nada ni lee el cuerpo completo del correo.

**No incluido, y por qué:**
- Leer WhatsApp/Instagram/apps bancarias por dentro, o "controlar" otra app como si fueras tú: iOS no expone eso a ninguna app de terceros, jailbreak included solo con muchísimo riesgo de seguridad — no lo vamos a hacer.
- "Hey Jarvis" en segundo plano de forma indefinida (con el móvil bloqueado o la app cerrada): el reconocimiento de voz de Apple no puede correr sin fin en background. Si quieres eso, se añade con un motor de terceros (p.ej. Picovoice Porcupine) — es un paso aparte. Mientras la app está **abierta y en primer plano**, sí escucha todo el rato sin tener que pulsar nada (ver más abajo).
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

### Que el Mac no se duerma

Mientras el Mac esté dormido (aunque siga enchufado), el servidor no
funciona — el sistema entero se pausa, no solo la pantalla. Para que no se
duerma solo:

1.  → **Preferencias del Sistema** → **Ahorro de energía** (Energy Saver).
2. Marca **"Evitar que el equipo se duerma automáticamente cuando la pantalla esté apagada"**.
3. Puedes dejar que la pantalla se apague igualmente (ahorra algo de luz), solo importa que el equipo en sí no entre en reposo.

### Usar Jarvis fuera de casa, desde cualquier sitio

Por defecto, el móvil solo puede hablar con el servidor si está en la
**misma red Wi-Fi** que el Mac (la IP `192.168.x.x` no se puede alcanzar
desde fuera de casa). Para usarlo con datos móviles o desde cualquier otra
red, monta [Tailscale](https://tailscale.com) (gratis para uso personal):
crea una red privada cifrada entre tu iPhone y el Mac, sin tocar nada del
router ni exponer el servidor a internet abierto.

1. En el Mac: descarga Tailscale desde **tailscale.com/download** (o desde la Mac App Store), instálalo y ábrelo.
2. Inicia sesión — puedes usar tu cuenta de Google, Microsoft, GitHub o un email normal. Es gratis.
3. En el iPhone: instala la app **Tailscale** desde la App Store, ábrela e inicia sesión con **la misma cuenta**.
4. En el Mac, haz clic en el icono de Tailscale (arriba a la derecha, en la barra de menús) → verás algo como **"This device: 100.x.x.x"** — esa es la IP de Tailscale de tu Mac. Apúntala (o consíguela desde Terminal con `tailscale ip -4`).
5. En el iPhone, en Ajustes de Jarvis, cambia el **Server URL** por esa IP en vez de la local: `ws://100.x.x.x:8787`.

Con esto, mientras el Mac esté encendido (no dormido) y con Tailscale
abierto, y el iPhone tenga Tailscale activo (funciona solo en segundo
plano, no hace falta abrirlo cada vez), Jarvis funcionará desde cualquier
sitio con internet, no solo en casa.

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

## Escucha continua (sin pulsar el micrófono)

Con la app **abierta y en primer plano**, Jarvis escucha todo el rato sin
que tengas que tocar nada:
- Al abrir la app te saluda en voz alta ("Buenas, señor Gimeno...") y
  empieza a escuchar automáticamente.
- Cuando dejas de hablar (~1,3 segundos de silencio), envía lo que ha oído,
  te responde, y en cuanto termina de hablar **vuelve a escuchar solo**,
  sin que pulses nada — así puedes seguir la conversación de corrido.
- Si sales de la app o bloqueas el móvil, deja de escuchar automáticamente
  (no puede seguir en segundo plano, como ya se explicó arriba), y retoma
  al volver a abrirla.
- El botón del micrófono sigue ahí como control manual: pulsarlo mientras
  escucha fuerza el envío inmediato sin esperar el silencio; pulsarlo
  estando parado, lo reactiva a mano.

**Respuesta escrita en vez de hablada:** si en tu frase dices la palabra
**"escríbeme"** (en cualquier parte, ej. "escríbeme la lista de la compra"),
Jarvis no la lee en voz alta — en su lugar aparece una pantalla con el texto
de la respuesta, con una **X** arriba a la izquierda para cerrarla y volver
a la pantalla normal de voz.

**Aviso importante:** esto significa que el micrófono capta *todo* lo que
se diga cerca del móvil mientras la app esté abierta en pantalla, no solo
lo que te diriges a Jarvis — incluida conversación de fondo que no era para
él. Cada vez que detecta un silencio después de "algo", se lo manda a
Claude (consume uso de tu suscripción) e intentará responder. Si prefieres
volver al modo "pulsa para hablar" de toda la vida, dímelo y lo dejo como
opción activable en Ajustes en vez de comportamiento por defecto.

## Crear y leer Notas (requiere configurar 2 Atajos, una sola vez)

Apple no da a ninguna app de terceros acceso directo a Notas (a diferencia
de Calendario/Recordatorios/Contactos, que sí tienen un framework
público). El único camino real es pasar por la app **Atajos**, que sí
tiene ese acceso especial. Por eso, para que Jarvis pueda crear o leer
notas, tienes que construir **dos Atajos tú mismo, una sola vez** — a
partir de ahí funciona solo por voz.

**Atajo 1 — "Jarvis Crear Nota"**
1. Abre la app **Atajos** → pestaña **Mis Atajos** → **+** (nuevo atajo).
2. Toca el nombre por defecto y ponle exactamente: **`Jarvis Crear Nota`** (respeta mayúsculas y espacios).
3. Añade la acción **"Crear nota"** (busca "nota" en el buscador de acciones).
4. En el contenido de esa acción, usa la variable **"Entrada rápida"** (Shortcut Input) — es el texto que le va a mandar Jarvis, no escribas nada fijo ahí.
5. Añade una última acción **"Texto"** con algo como `Nota creada` (esto es lo que Jarvis recibe de vuelta como confirmación).
6. Toca el icono de ajustes del atajo (los "···" o el icono de información) y **desactiva "Preguntar antes de ejecutar"** — importante, si no, cada vez te saldrá un aviso pidiendo confirmar.

**Atajo 2 — "Jarvis Leer Nota"**
1. Nuevo atajo, nómbralo exactamente: **`Jarvis Leer Nota`**.
2. Añade la acción **"Buscar notas"** (Find Notes), y configúrala para buscar donde **"Nombre" contiene "Entrada rápida"**.
3. Añade la acción **"Obtener detalles de notas"** (Get Details of Notes), pidiendo el **"Texto sin formato"** (o "Cuerpo") de las notas encontradas.
4. Asegúrate de que esa sea la **última acción** del atajo (su resultado es lo que Jarvis recibe y te lee).
5. Igual que el anterior, **desactiva "Preguntar antes de ejecutar"**.

Con los dos creados, podrás decirle cosas como *"Créame una nota con la receta de tarta de queso que me diste"* o *"Léeme la nota de entrenamiento físico"*, y Jarvis se encarga del resto.

**Aviso honesto:** es la parte más "artesanal" de todo el proyecto — depende de que los Atajos estén construidos exactamente así, y los nombres de las acciones en Atajos pueden variar ligeramente según tu versión de iOS. Si al probarlo no funciona, mándame una captura de cómo tienes montado el Atajo y lo ajustamos juntos. Cada llamada puede tardar unos segundos de más porque pasa por la app Atajos por el camino.

## Alarmas y temporizadores (requiere configurar 2 Atajos más)

Mismo motivo que con Notas: Apple no da a ninguna app de terceros acceso
directo a la app Reloj, así que Jarvis pasa por dos Atajos que construyes
tú una sola vez.

**Aviso honesto sobre los límites:** Jarvis puede **crear alarmas nuevas**
y **poner temporizadores nuevos** por voz. Eso es todo. Apple **no permite
a ninguna app** (ni siquiera a Atajos) **leer las alarmas que ya tienes
puestas**, **decir cuánto tiempo queda de un temporizador en marcha**, ni
**iniciar o controlar el cronómetro**. No es una limitación de este
proyecto — es que esa información y esos controles no están disponibles
para nadie fuera de la propia app Reloj de Apple.

**Atajo 1 — "Jarvis Crear Alarma"**

Jarvis manda la hora y el nombre juntos en un solo texto, separados por `|`
(ej. `07:30|Gimnasio`), porque Atajos solo permite pasar un texto por
llamada. Por eso hace falta separarlos dentro del propio Atajo:

1. Nuevo atajo, nómbralo exactamente: **`Jarvis Crear Alarma`**.
2. Añade la acción **"Dividir texto"** (Split Text). Configúrala para dividir **"Entrada de atajo"** usando un separador personalizado: **`|`**.
3. Añade la acción **"Añadir alarma"** (o "Crear alarma", según tu versión).
   - En el campo de la **hora**, usa **"Seleccionar variable"** → el resultado de "Dividir texto" → elige el **primer elemento** (índice 1).
   - En el campo del **nombre/título** de la alarma, haz lo mismo pero eligiendo el **segundo elemento** (índice 2).
4. Añade una última acción **"Detener y generar"** con el resultado puesto a texto fijo, por ejemplo `Alarma creada`.
5. Desactiva **"Preguntar antes de ejecutar"** en los ajustes del atajo.

Si al insertar la variable de "Dividir texto" en un campo no te deja elegir directamente "primer/segundo elemento", añade dos acciones **"Obtener elemento de lista"** antes del paso 3 (una para el índice 1, otra para el índice 2) y usa esos resultados en su lugar.

**Atajo 2 — "Jarvis Iniciar Temporizador"**
1. Nuevo atajo, nómbralo exactamente: **`Jarvis Iniciar Temporizador`**.
2. Añade la acción **"Iniciar temporizador"**, con la duración puesta en **minutos** y usando la variable **"Entrada de atajo"** como cantidad.
3. Añade una última acción **"Detener y generar"** con el resultado a texto fijo, por ejemplo `Temporizador iniciado`.
4. Desactiva **"Preguntar antes de ejecutar"**.

Con los dos creados, podrás decir cosas como *"Jarvis, ponme una alarma a las 7 y media"* o *"Jarvis, ponme un temporizador de 10 minutos"*. Si le pides que te diga qué alarmas tienes o cuánto queda de un temporizador, te dirá que no puede — es la limitación de Apple explicada arriba, no un fallo.

## Enviar fotos o archivos para que Jarvis los vea

Si en cualquier momento le dices algo que combine una palabra de foto/imagen/archivo con una palabra de enviar/mandar (ej. *"Jarvis, te voy a enviar una foto de este ejercicio, ayúdame a resolverlo"*), aparece un menú con tres opciones: **Fototeca**, **Cámara** y **Archivo**. Eliges una, seleccionas o haces la foto, y se manda junto con lo que le pediste — Claude la ve de verdad y responde según lo que aparezca en la imagen. No requiere ningún Atajo ni configuración adicional, funciona directamente. "Archivo" por ahora solo admite imágenes (no PDFs u otros documentos).

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
