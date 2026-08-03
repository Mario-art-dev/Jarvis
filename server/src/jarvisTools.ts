import { z } from "zod";
import { tool, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { fetchWeather } from "./weather.js";
import { checkGmail } from "./gmail.js";

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
        "Abre una app o acción del sistema en el iPhone: maps, mail, messages, phone, facetime, camera, calendar, reminders, settings, whatsapp, spotify, instagram.",
        {
          target: z.enum([
            "maps", "google_maps", "mail", "messages", "phone", "facetime", "camera",
            "calendar", "reminders", "settings", "whatsapp", "spotify",
            "instagram", "tiktok", "youtube", "gmail", "chrome", "teams",
            "app_store", "music", "notes", "voice_memos", "files",
            "chatgpt", "claude", "netflix", "prime_video", "movistar_plus",
            "hbo_max", "brawl_stars", "clash_royale", "capcut", "canva",
            "clock", "weather"
          ]),
          query_or_recipient: z.string().optional().describe(
            "Opcional: dirección para maps/google_maps, destinatario para messages/mail/phone/whatsapp, término de búsqueda para youtube/app_store."
          )
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("open_app", args) }]
        })
      ),
      tool(
        "search_photos",
        "Busca fotos en la galería del iPhone por rango de fechas, favoritas o capturas de pantalla. Con content_query, además clasifica el contenido (ej. 'dog', 'beach', 'car') sobre las fotos más recientes que cumplan el filtro, usando el clasificador de imágenes de Apple en el propio iPhone.",
        {
          filter: z.enum(["recent", "favorites", "screenshots", "today"]),
          limit: z.number().int().optional(),
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
        "Crea o lista eventos del calendario del iPhone. action=create requiere title y start_iso8601.",
        {
          action: z.enum(["create", "list_today"]),
          title: z.string().optional(),
          start_iso8601: z.string().optional(),
          end_iso8601: z.string().optional()
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
