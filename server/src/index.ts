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
Usa las herramientas disponibles cuando la petición del usuario lo requiera \
(buscar en internet, abrir apps, gestionar calendario, recordatorios o \
contactos, o consultar fotos). Si no tienes una herramienta para algo, dilo \
con claridad en vez de inventar que lo hiciste. No tienes acceso a un \
sistema de archivos ni a una terminal: todo lo que hagas en el mundo real \
pasa por esas herramientas, que se ejecutan en el iPhone del usuario.`;

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
      // over a batch of photos, which can take longer than a plain lookup.
      const timeoutMs = name === "search_photos" ? 60_000 : 25_000;
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
            tools: [], // desactiva Bash/Read/Write/etc: solo existen nuestras tools de iPhone
            allowedTools: [
              "mcp__jarvis__web_search",
              "mcp__jarvis__open_app",
              "mcp__jarvis__search_photos",
              "mcp__jarvis__calendar",
              "mcp__jarvis__reminders",
              "mcp__jarvis__search_contacts",
              "mcp__jarvis__get_weather"
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
