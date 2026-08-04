import "dotenv/config";
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { WebSocketServer, type WebSocket } from "ws";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { createJarvisToolServer } from "./jarvisTools.js";
import { loadProfile } from "./profile.js";

const PORT = Number(process.env.PORT ?? 8787);
const AUTH_TOKEN = process.env.JARVIS_SERVER_TOKEN;

// The phone opens a fresh WebSocket per turn (see JarvisServerClient), so
// conversation memory can't live on the connection — it has to be a single
// value shared across every connection, persisted to disk so it survives
// server restarts too. This is what makes Jarvis actually remember earlier
// turns instead of starting from scratch every time he's asked something.
const __dirname = dirname(fileURLToPath(import.meta.url));
const SESSION_FILE = join(__dirname, "..", ".jarvis-session-id");

function loadSessionId(): string | undefined {
  try {
    const saved = readFileSync(SESSION_FILE, "utf8").trim();
    return saved || undefined;
  } catch {
    return undefined;
  }
}

function saveSessionId(id: string) {
  try {
    writeFileSync(SESSION_FILE, id, "utf8");
  } catch (error) {
    console.error("No pude guardar la sesión de Jarvis:", error);
  }
}

let sessionId: string | undefined = loadSessionId();

if (!AUTH_TOKEN) {
  console.error(
    "Falta JARVIS_SERVER_TOKEN en el entorno. Copia .env.example a .env y define un token secreto."
  );
  process.exit(1);
}

const SYSTEM_PROMPT = `Eres Jarvis, el asistente personal de voz de Mario. Te diriges a él como \
"señor Gimeno". Este mismo teléfono y esta misma app también las usan sus \
hijos, que son menores — no tienes forma de saber quién te habla en cada \
momento, así que mantén siempre un tono y un contenido apropiados para \
cualquier edad: nada violento, sexual, de miedo excesivo o inapropiado \
para niños, y si te piden algo que claramente requiere el juicio de un \
adulto (dinero, salud, algo peligroso, contactar a desconocidos...), \
sugiere que lo hablen con un adulto en vez de simplemente hacerlo. Si el \
usuario comparte un dato duradero sobre sí mismo, su \
familia o sus preferencias (no algo puntual del día a día), guárdalo con \
mcp__jarvis__remember_fact para recordarlo siempre a partir de entonces. \
Respondes siempre en \
español, de forma natural porque tus respuestas se leen en voz alta — para \
datos simples sé breve, pero cuando te pidan una recomendación o decisión \
que depende de varios factores (ej. "¿a qué hora es mejor ir hoy al \
gimnasio?", "¿debería llevar paraguas?", comparar opciones...) no des una \
respuesta plana: identifica qué factores importan, consigue datos reales \
para esos factores con tus herramientas (el tiempo con \
mcp__jarvis__get_weather, cosas que no sepas con WebSearch — ej. cuándo \
suele haber más o menos gente en sitios así, en general), razona \
combinándolos en voz alta de forma breve pero clara, y termina con una \
recomendación concreta y el motivo. Prioriza siempre razonar con datos \
reales antes que responder solo con suposiciones genéricas. \
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
mucho dejas el chat abierto y lo dices claramente. Si te piden recomendaciones de sitios (restaurantes, bares, tiendas...) en \
un lugar, usa WebSearch/WebFetch para buscar opciones reales y sus reseñas \
por internet, decide y explica cuál recomiendas y por qué, y después usa \
mcp__jarvis__open_app con target=maps (o google_maps) y ese sitio como \
query_or_recipient para abrírselo en el móvil y que pueda ir. Nunca puedes \
leer las reseñas dentro de la propia app Maps — la recomendación sale \
siempre de la búsqueda web, no de mirar dentro de la app. Cuando el usuario te envíe una foto (aparecerá como imagen adjunta en su \
mensaje), analízala y responde a lo que te haya pedido sobre ella con \
naturalidad, como si la estuvieras viendo — porque la estás viendo. \
Para alarmas y temporizadores usa mcp__jarvis__clock_action: puedes crear \
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

      // Photos the user attached (via the "te voy a enviar una foto" flow)
      // ride along as image content blocks in the same turn, instead of a
      // plain string prompt.
      const images: Array<{ media_type?: string; data?: string }> = Array.isArray(msg.images) ? msg.images : [];
      const validImages = images.filter(
        (img): img is { media_type: string; data: string } => typeof img.media_type === "string" && typeof img.data === "string"
      );

      const prompt = validImages.length > 0
        ? (async function* () {
            yield {
              type: "user" as const,
              message: {
                role: "user" as const,
                content: [
                  { type: "text" as const, text },
                  ...validImages.map((img) => ({
                    type: "image" as const,
                    source: { type: "base64" as const, media_type: img.media_type as "image/jpeg" | "image/png" | "image/gif" | "image/webp", data: img.data }
                  }))
                ]
              },
              parent_tool_use_id: null
            };
          })()
        : text;

      // Re-read on every turn (not once at startup) so a fact remembered a
      // moment ago is already known on the very next message, and this
      // stays present even if the resumed session itself ever gets summarized.
      const profile = loadProfile();
      const systemPrompt = profile
        ? `${SYSTEM_PROMPT}\n\nDatos permanentes que ya sabes sobre el usuario:\n${profile}`
        : SYSTEM_PROMPT;

      try {
        const stream = query({
          prompt,
          options: {
            systemPrompt,
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
              "mcp__jarvis__clock_action",
              "mcp__jarvis__files_content",
              "mcp__jarvis__remember_fact"
            ],
            permissionMode: "bypassPermissions",
            allowDangerouslySkipPermissions: true,
            ...(sessionId ? { resume: sessionId } : {})
          }
        });

        for await (const event of stream) {
          if (event.type === "result") {
            sessionId = event.session_id;
            saveSessionId(sessionId);
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
