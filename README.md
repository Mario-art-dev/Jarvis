# Jarvis — asistente de voz personal para iPhone

App iOS (SwiftUI) con interfaz HUD, reconocimiento de voz, un "cerebro"
basado en Claude (Anthropic) con tool-calling, y respuestas habladas con tu
voz clonada en ElevenLabs. Puede abrir apps, buscar en internet, y leer/crear
eventos, recordatorios y contactos con tu permiso.

## Qué es realmente posible en iOS (léelo antes de nada)

Pediste "acceso máximo posible a todo el móvil". En Android eso incluiría
control profundo del sistema; en **iOS, sin jailbreak, Apple no lo permite a
ninguna app**, por diseño (sandboxing). Esta app te da el máximo real dentro
de esas reglas:

**Sí incluido:**
- Escuchar y transcribir tu voz, y responder con audio generado por ElevenLabs con tu voz clonada.
- Decidir qué hacer usando Claude como cerebro (tool-calling / function calling).
- Abrir cualquier app que tenga un URL scheme público (Mapas, Mail, Mensajes, Teléfono, FaceTime, Cámara, Calendario, Recordatorios, Ajustes, WhatsApp, Spotify, Instagram...).
- Abrir búsquedas en Safari.
- Leer y crear eventos de Calendario y Recordatorios (con tu permiso, vía EventKit).
- Buscar contactos por nombre (vía Contacts framework).
- Contar/buscar fotos en tu galería por fecha, favoritas o capturas (vía Photos framework). Búsqueda por *contenido* ("fotos de la playa") no está incluida: requeriría un modelo de visión aparte; se puede añadir después si lo quieres.

**No incluido, y por qué:**
- Leer WhatsApp/Instagram/apps bancarias por dentro, o "controlar" otra app como si fueras tú: iOS no expone eso a ninguna app de terceros, jailbreak included solo con muchísimo riesgo de seguridad — no lo vamos a hacer.
- "Hey Jarvis" en segundo plano de forma indefinida: el reconocimiento de voz de Apple no puede correr sin fin en background. La app usa manos-libres tipo "pulsa para hablar". Si quieres wake-word real, se añade con un motor de terceros (p.ej. Picovoice Porcupine) — es un paso aparte.
- Leer resultados de una búsqueda web: Jarvis puede *abrir* Safari con la búsqueda ya hecha, pero no puede leer lo que hay en la pantalla de otra app.

## Arquitectura

```
Sources/JarvisApp/
  JarvisApp.swift              # punto de entrada
  Views/
    HUDView.swift               # interfaz circular tipo la de tu imagen
    ConversationView.swift      # pantalla principal (mic, transcript)
    SettingsView.swift          # introducir claves API
  Core/
    Config/
      SecureStore.swift         # Keychain (nunca guardamos claves en texto plano)
      AppConfig.swift
    Voice/
      SpeechRecognizer.swift    # voz -> texto (Speech framework)
      ElevenLabsClient.swift    # texto -> audio con tu voz clonada
      AudioPlayer.swift
    Brain/
      ClaudeClient.swift        # llamada a la API de Anthropic con tool-use
      ConversationEngine.swift  # orquesta: escuchar -> pensar -> actuar -> hablar
    Tools/
      ToolProtocol.swift        # contrato + registro de herramientas
      WebSearchTool.swift
      AppLauncherTool.swift
      PhotosTool.swift
      CalendarTool.swift
      RemindersTool.swift
      ContactsTool.swift
```

Cada "tool" es una capacidad concreta con permisos explícitos de iOS. Claude
recibe la lista de herramientas disponibles en cada turno y decide cuál
llamar según lo que pidas por voz — así es como se añade "acceso" real sin
dar un permiso indiscriminado de golpe.

## 1. Crear tu voz clonada en ElevenLabs

1. Crea cuenta en https://elevenlabs.io (tiene plan gratuito limitado).
2. Ve a **Voices → Add Voice → Instant Voice Clone**.
3. Sube 1-3 minutos de audio tuyo hablando claro, sin ruido de fondo.
4. Dale nombre (p.ej. "Mario") y guarda.
5. Entra en esa voz y copia su **Voice ID** (aparece en la URL o en "..." → Copy Voice ID).
6. Ve a tu perfil → **API Keys** y genera una API key.

## 2. Crear tu API key de Anthropic (Claude)

1. Crea cuenta en https://console.anthropic.com
2. Añade método de pago (la API es de pago por uso, no el plan de claude.ai).
3. Ve a **Settings → API Keys → Create Key** y cópiala (empieza por `sk-ant-`).

## 3. Generar el proyecto de Xcode

Este repo no incluye un `.xcodeproj` binario (se genera con
[XcodeGen](https://github.com/yonaskolb/XcodeGen) a partir de `project.yml`,
así el proyecto no se corrompe al fusionar cambios en git).

En tu Mac:

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

## 4. Primer arranque

1. Abre la app en el iPhone. Como no hay claves guardadas, se abrirá **Ajustes**.
2. Pega tu API key de Anthropic, tu API key de ElevenLabs y el Voice ID. Guardar.
3. Pulsa el micrófono, di algo como *"Búscame los mejores restaurantes de Madrid"* o *"Qué tengo hoy en el calendario"*.
4. Jarvis te responderá en voz alta con tu voz clonada.

## Seguridad de las claves

- Las claves se guardan en el **Keychain de iOS**, cifradas, nunca en
  UserDefaults ni en el código fuente ni en este repositorio.
- No subas nunca tus claves a git. Si algún día las pegas por error en un
  commit, revócalas inmediatamente desde el dashboard de Anthropic/ElevenLabs
  y genera unas nuevas.

## Ampliar Jarvis

Para añadir una nueva capacidad, crea un `struct` que implemente
`JarvisTool` (ver `Core/Tools/ToolProtocol.swift`) y regístralo en
`ToolRegistry.init()`. Claude lo verá automáticamente como una opción más
la próxima vez que le pidas algo relacionado.
