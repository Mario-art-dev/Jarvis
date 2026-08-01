import { z } from "zod";
import { tool, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";

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
            "maps", "mail", "messages", "phone", "facetime", "camera",
            "calendar", "reminders", "settings", "whatsapp", "spotify", "instagram"
          ]),
          query_or_recipient: z.string().optional().describe(
            "Opcional: dirección para maps, destinatario para messages/mail/phone, etc."
          )
        },
        async (args) => ({
          content: [{ type: "text", text: await callOnPhone("open_app", args) }]
        })
      ),
      tool(
        "search_photos",
        "Busca fotos en la galería del iPhone por rango de fechas, favoritas o capturas de pantalla.",
        {
          filter: z.enum(["recent", "favorites", "screenshots", "today"]),
          limit: z.number().int().optional()
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
      )
    ]
  });
}
