import "dotenv/config";
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocketServer, type WebSocket } from "ws";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { createJarvisToolServer } from "./jarvisTools.js";

const PORT = Number(process.env.PORT ?? 8787);
const AUTH_TOKEN = process.env.JARVIS_SERVER_TOKEN;

if (!AUTH_TOKEN) {
  console.error(
    "Falta JARVIS_SERVER_TOKEN en el entorno. Copia .env.example a .env y define un token secreto."
  );
  process.exit(1);
}

const SYSTEM_PROMPT = `Eres Jarvis, el asistente personal de voz de Mario. Respondes siempre en \
español, de forma breve y natural porque tus respuestas se leen en voz alta. \
Para preguntas que necesiten información real de internet (precios, noticias, \
datos actuales, comparar cosas...) usa las herramientas WebSearch y WebFetch \
para buscar y leer la web de verdad, y responde con lo que encuentres — no \
hace falta abrir nada en el móvil para esto. Usa la herramienta \
mcp__jarvis__web_search SOLO cuando el usuario quiera ver la búsqueda él \
mismo en la pantalla del iPhone. Usa el resto de herramientas de Jarvis \
cuando la petición lo requiera (abrir apps, gestionar calendario, \
recordatorios o contactos, consultar fotos, el tiempo, música o Gmail). \
Si te piden llamar, escribir o abrir el chat de alguien por WhatsApp (o \
FaceTime/Mensajes/Teléfono) usando un nombre en vez de un número, primero \
usa mcp__jarvis__search_contacts para sacar el teléfono de esa persona, \
limpia el número (sin espacios/paréntesis, con prefijo de país si hace \
falta) y pásalo como query_or_recipient a mcp__jarvis__open_app. Nunca \
puedes pulsar el botón de llamar/enviar dentro de otra app ni leer los \
chats o archivos de WhatsApp — eso no lo permite iOS a ninguna app; como \
mucho dejas el chat abierto y lo dices claramente. Para alarmas y temporizadores usa mcp__jarvis__clock_action: puedes crear \
alarmas nuevas y poner temporizadores, pero nunca puedes leer las alarmas \
existentes, decir cuánto tiempo queda de un temporizador, ni controlar el \
cronómetro — Apple no lo permite a ninguna app, dilo con claridad si te lo \
piden. Si no tienes una \
herramienta para algo, dilo con claridad en vez de inventar que lo hiciste. \
No tienes acceso a un sistema de archivos ni a una terminal en este Mac: \
todo lo que hagas en el mundo real pasa por esas herramientas, que se \
ejecutan en el iPhone del usuario (salvo la búsqueda web y el tiempo, que \
corren aquí mismo).`;

type PendingCall = {
  resolve: (text: string) => void;
  timeout: NodeJS.Timeout;
};

const httpServer = createServer((_req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Jarvis server OK\n");
});

const wss = new WebSocketServer({
  server: httpServer,
  verifyClient: (info, callback) => {
    const header = info.req.headers["authorization"];
    const ok = header === `Bearer ${AUTH_TOKEN}`;
    if (!ok) {
      callback(false, 401, "Unauthorized");
    } else {
      callback(true);
    }
  }
});

wss.on("connection", (ws: WebSocket) => {
  console.log("Teléfono conectado.");
  let sessionId: string | undefined;
  const pending = new Map<string, PendingCall>();

  const callOnPhone = (name: string, input: Record<string, unknown>): Promise<string> => {
    const id = randomUUID();
    return new Promise((resolve) => {
      // search_photos with content_query runs on-device image classification
      // over a batch of photos, and notes_content round-trips through the
      // Shortcuts app — both can take longer than a plain lookup.
      const timeoutMs = name === "search_photos" ? 60_000 : name === "notes_content" || name === "clock_action" ? 30_000 : 25_000;
      const timeout = setTimeout(() => {
        pending.delete(id);
        resolve(`La app no respondió a tiempo ejecutando ${name}.`);
      }, timeoutMs);
      pending.set(id, { resolve, timeout });
      ws.send(JSON.stringify({ type: "tool_call", id, name, input }));
    });
  };

  const toolServer = createJarvisToolServer(callOnPhone);

  ws.on("message", async (raw) => {
    let msg: any;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      ws.send(JSON.stringify({ type: "error", message: "JSON inválido" }));
      return;
    }

    if (msg.type === "tool_result") {
      const entry = pending.get(msg.id);
      if (entry) {
        clearTimeout(entry.timeout);
        pending.delete(msg.id);
        entry.resolve(String(msg.result ?? ""));
      }
      return;
    }

    if (msg.type === "user_message") {
      const text = String(msg.text ?? "");
      if (!text.trim()) return;

      try {
        const stream = query({
          prompt: text,
          options: {
            systemPrompt: SYSTEM_PROMPT,
            mcpServers: { jarvis: toolServer },
            // Solo WebSearch/WebFetch de las tools normales de Claude Code —
            // permiten buscar y leer la web de verdad. Bash/Read/Write/Edit
            // y el resto siguen desactivadas: nunca tocan archivos ni
            // ejecutan comandos en este Mac.
            tools: ["WebSearch", "WebFetch"],
            allowedTools: [
              "WebSearch",
              "WebFetch",
              "mcp__jarvis__web_search",
              "mcp__jarvis__open_app",
              "mcp__jarvis__search_photos",
              "mcp__jarvis__calendar",
              "mcp__jarvis__reminders",
              "mcp__jarvis__search_contacts",
              "mcp__jarvis__get_weather",
              "mcp__jarvis__play_music",
              "mcp__jarvis__check_gmail",
              "mcp__jarvis__notes_content",
              "mcp__jarvis__clock_action"
            ],
            permissionMode: "bypassPermissions",
            allowDangerouslySkipPermissions: true,
            ...(sessionId ? { resume: sessionId } : {})
          }
        });

        for await (const event of stream) {
          if (event.type === "result") {
            sessionId = event.session_id;
            if (event.subtype === "success") {
              ws.send(JSON.stringify({ type: "final_answer", text: event.result }));
            } else {
              ws.send(JSON.stringify({
                type: "error",
                message: `Jarvis no pudo terminar la respuesta (${event.subtype}).`
              }));
            }
          }
        }
      } catch (error) {
        ws.send(JSON.stringify({
          type: "error",
          message: error instanceof Error ? error.message : "Error desconocido"
        }));
      }
      return;
    }
  });

  ws.on("close", () => {
    console.log("Teléfono desconectado.");
    for (const entry of pending.values()) {
      clearTimeout(entry.timeout);
    }
    pending.clear();
  });
});

httpServer.listen(PORT, () => {
  console.log(`Jarvis server escuchando en :${PORT}`);
});
