import { z } from "zod";
import { tool, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { fetchWeather } from "./weather.js";
import { checkGmail } from "./gmail.js";
import { rememberFact } from "./profile.js";

/**
 * These tool names/schemas mirror Sources/JarvisApp/Core/Tools/*.swift on the
 * phone. The server never executes anything itself — every handler just
 * forwards the call to whichever iPhone is connected over the WebSocket and
 * waits for that phone's native code (Photos/EventKit/Contacts/UIApplication)
 * to run it and reply. Keep this file and the Swift tools in sync by hand;
 * there's no shared schema source across Swift/TypeScript.
 */
export type ToolCallProxy = (name: string, input: Record<string, unknown>) => Promise<string>;

export function createJarvisToolServer(callOnPhone: ToolCallProxy) {
  return createSdkMcpServer({
    name: "jarvis",
    version: "1.0.0",
    tools: [
      tool(
        "web_search",
        "Abre una búsqueda en Safari para una consulta dada en el iPhone del usuario.",
        { query: z.string().describe("Texto a buscar") },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("web_search", args) }]
        })
      ),
      tool(
        "open_app",
        "Abre una app o acción del sistema en el iPhone: maps, mail, messages, phone, facetime, camera, photos (la app Fotos), calendar, reminders, settings, whatsapp, spotify, instagram.",
        {
          target: z.enum([
            "maps", "google_maps", "mail", "messages", "phone", "facetime", "facetime_audio", "camera",
            "photos", "calendar", "reminders", "settings", "whatsapp", "spotify",
            "instagram", "tiktok", "youtube", "gmail", "chrome", "teams",
            "app_store", "music", "notes", "voice_memos", "files",
            "safari", "google", "shortcuts", "marca",
            "chatgpt", "claude", "netflix", "prime_video", "movistar_plus",
            "hbo_max", "brawl_stars", "clash_royale", "capcut", "canva",
            "clock", "weather", "liftoff_gym", "rider_stunt_bike"
          ]),
          query_or_recipient: z.string().optional().describe(
            "Opcional: dirección para maps/google_maps, destinatario para messages/mail/phone/whatsapp, término de búsqueda para youtube/app_store/chrome/safari/google."
          )
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("open_app", args) }]
        })
      ),
      tool(
        "search_photos",
        "Busca fotos en la galería del iPhone. filter=all busca en TODA la fototeca; recent/favorites/screenshots/today acotan la búsqueda. Con content_query además clasifica el contenido (ej. 'dog', 'beach', 'car') con el clasificador de imágenes de Apple en el propio iPhone; en fototecas muy grandes revisa las más recientes que le dé tiempo y te dice cuántas revisó.",
        {
          filter: z.enum(["all", "recent", "favorites", "screenshots", "today"]),
          content_query: z.string().optional().describe(
            "Palabra en inglés que describe el contenido a buscar (ej. 'dog', 'cat', 'beach', 'car'). Traduce el término del usuario al inglés antes de llamar a la herramienta."
          )
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("search_photos", args) }]
        })
      ),
      tool(
        "calendar",
        "Crea o consulta eventos del calendario del iPhone. Para crear: action=create con title y start_iso8601. Para consultar: list_today (hoy), list_week (próximos 7 días), list_month (próximos 30 días), o list_range con start_iso8601/end_iso8601 para cualquier otro periodo (ej. un mes concreto, el fin de semana que viene).",
        {
          action: z.enum(["create", "list_today", "list_week", "list_month", "list_range"]),
          title: z.string().optional(),
          start_iso8601: z.string().optional().describe("Para create: cuándo empieza el evento. Para list_range: desde cuándo consultar."),
          end_iso8601: z.string().optional().describe("Para create: cuándo acaba (por defecto 1h después). Para list_range: hasta cuándo consultar.")
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("calendar", args) }]
        })
      ),
      tool(
        "reminders",
        "Crea o lista recordatorios pendientes en el iPhone. action=create requiere title.",
        {
          action: z.enum(["create", "list_pending"]),
          title: z.string().optional(),
          due_iso8601: z.string().optional()
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("reminders", args) }]
        })
      ),
      tool(
        "search_contacts",
        "Busca contactos por nombre en el iPhone y devuelve nombre y teléfono.",
        { name: z.string() },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("search_contacts", args) }]
        })
      ),
      tool(
        "play_music",
        "Reproduce una playlist de la app Música del iPhone por nombre, opcionalmente aleatoria (shuffle). Solo encuentra playlists ya guardadas en la biblioteca del usuario.",
        {
          playlist_name: z.string().describe("Nombre (o parte del nombre) de la playlist a buscar"),
          shuffle: z.boolean().optional().describe("Si es true, activa reproducción aleatoria")
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("play_music", args) }]
        })
      ),
      tool(
        "music_control",
        "Controla la reproducción actual de la app Música del iPhone: pausar, reanudar, siguiente/anterior canción, y subir/bajar el volumen del dispositivo.",
        {
          action: z.enum(["pause", "resume", "next", "previous", "volume_up", "volume_down"])
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("music_control", args) }]
        })
      ),
      tool(
        "notes_content",
        "Crea una nota nueva con un contenido dado, o lee el contenido de una nota existente por título, en la app Notas del iPhone. Requiere que el usuario tenga configurados los Atajos \"Jarvis Crear Nota\" y \"Jarvis Leer Nota\" — puede tardar hasta 20s en responder porque pasa por la app Atajos.",
        {
          action: z.enum(["create", "read"]),
          title: z.string().describe("Para create: título de la nota nueva. Para read: título (o parte) de la nota a buscar."),
          content: z.string().optional().describe("Solo para create: el texto de la nota.")
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("notes_content", args) }]
        })
      ),
      tool(
        "clock_action",
        "Crea alarmas y temporizadores en el iPhone, y consulta (list_pending) o cancela (cancel_all) los que haya puestos. No requiere ninguna configuración previa. Son notificaciones de la propia app Jarvis: suenan como una notificación normal, así que NO atraviesan el modo silencio ni el modo concentración, suenan una vez en vez de hasta que las apagues, y no aparecen en la app Reloj de Apple. Si el usuario necesita una alarma para despertarse de verdad, dile que la ponga también en la app Reloj.",
        {
          action: z.enum(["create_alarm", "start_timer", "list_pending", "cancel_all"]),
          time_hhmm: z.string().optional().describe("Solo para create_alarm: hora en formato 24h HH:mm, ej. '07:30'."),
          label: z.string().optional().describe("Solo para create_alarm: nombre de la alarma, si el usuario pidió uno."),
          minutes: z.number().int().optional().describe("Solo para start_timer: minutos de cuenta atrás.")
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("clock_action", args) }]
        })
      ),
      tool(
        "files_content",
        "Crea, lee o lista archivos de texto en la carpeta de Jarvis dentro de la app Archivos del iPhone (\"En mi iPhone > Jarvis\"). Solo texto plano, no PDFs ni otros documentos, y solo dentro de esa carpeta.",
        {
          action: z.enum(["create", "read", "list"]),
          filename: z.string().optional().describe("Para create/read: nombre del archivo, ej. 'lista de la compra.txt'."),
          content: z.string().optional().describe("Solo para create: el texto del archivo.")
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("files_content", args) }]
        })
      ),
      tool(
        "remember_fact",
        "Guarda para siempre un dato permanente sobre el usuario, su familia o sus preferencias (ej. nombres de familiares, dónde vive, gustos, cosas básicas). Úsalo cuando comparta algo que claramente quiere que recuerdes de forma duradera, no para cosas puntuales del día a día como una tarea o un evento concreto.",
        { fact: z.string().describe("El dato a recordar, en una frase clara y autocontenida, ej. 'Su hermana se llama Laura y vive en Madrid.'") },
        async (args) => ({
          content: [{ type: "text", text: rememberFact(args.fact) }]
        })
      ),
      tool(
        "get_weather",
        "Consulta el tiempo actual real (temperatura, viento, humedad) en cualquier ciudad o lugar del mundo. Esta herramienta corre en el servidor, no en el iPhone.",
        { location: z.string().describe("Nombre de la ciudad o lugar, ej. 'Valencia' o 'Madrid, España'") },
        async (args) => ({
          content: [{ type: "text", text: await fetchWeather(args.location) }]
        })
      ),
      tool(
        "check_gmail",
        "Consulta cuántos correos sin leer hay en Gmail y sus remitentes/asuntos más recientes. Corre en el servidor, solo lectura. Si el usuario tiene varias cuentas configuradas y no especifica cuál, consulta todas.",
        {
          account: z.string().optional().describe(
            "Opcional: qué cuenta consultar si hay varias configuradas (ej. 'personal', 'trabajo', o el email). Si se omite, consulta todas."
          ),
          limit: z.number().int().optional().describe("Máximo de correos a listar por cuenta, por defecto 5")
        },
        async (args) => ({
          content: [{ type: "text", text: await checkGmail(args.account, args.limit) }]
        })
      )
    ]
  });
}
