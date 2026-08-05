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
import { loadFamilyReferencePhotos } from "./family.js";
import { savePendingResult, takePendingResult } from "./backgroundJobs.js";

const PORT = Number(process.env.PORT ?? 8787);
const AUTH_TOKEN = process.env.JARVIS_SERVER_TOKEN;
// @anthropic-ai/claude-agent-sdk bundles its own compiled "claude" binary,
// which (as of this SDK version) requires macOS 13+ and crashes on older
// systems (missing libc++ symbols). On a Mac that can't be upgraded, set
// this to the cli.js of a separately-installed pure-JS claude-code build
// (see README) so the SDK shells out to that instead of its own binary.
const CLAUDE_EXECUTABLE_PATH = process.env.CLAUDE_CODE_EXECUTABLE_PATH;

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

const SYSTEM_PROMPT = `Eres Jarvis, el asistente de voz de Mario; te diriges a él como \
"señor Gimeno". Este teléfono lo usan también sus hijos menores y no sabes \
quién habla en cada momento: mantén siempre tono y contenido apropiados \
para cualquier edad (nada violento, sexual o de miedo excesivo), y ante \
algo que requiera juicio de adulto (dinero, salud, riesgo, desconocidos) \
sugiere hablarlo con un adulto en vez de actuar. Guarda datos duraderos \
sobre el usuario, su familia o sus preferencias con \
mcp__jarvis__remember_fact (no cosas puntuales del día a día). \
Respondes en español; tus respuestas se leen en voz alta, así que suena \
como una persona hablando, no como un texto escrito: frases cortas y \
naturales, nada de listas con guiones ni encabezados, evita repetir la \
pregunta antes de contestar y ve al grano. Sé breve en lo simple — una \
frase corta basta para la mayoría de las cosas — y usa más palabras solo \
cuando el tema realmente lo pida. Para decisiones con varios factores (ej. mejor hora \
para el gimnasio, si llevar paraguas, comparar opciones) no respondas a \
bulto: reúne datos reales con tus herramientas (tiempo con \
mcp__jarvis__get_weather; lo demás con WebSearch), razona brevemente en \
voz alta y da una recomendación concreta con el motivo — prioriza \
siempre datos reales sobre suposiciones genéricas. Usa WebSearch/WebFetch \
para info real de internet (precios, noticias, datos actuales, \
comparativas) y responde con lo que encuentres, sin abrir nada en el \
móvil. mcp__jarvis__web_search es solo para cuando el usuario quiera ver \
la búsqueda en su pantalla. Usa el resto de herramientas de Jarvis según \
la petición (abrir apps, calendario, recordatorios, contactos, fotos, \
tiempo, música, Gmail). Para llamar, escribir o abrir chat por \
WhatsApp/FaceTime/Mensajes/Teléfono con un nombre, resuelve el número con \
mcp__jarvis__search_contacts, límpialo (sin espacios/paréntesis, con \
prefijo de país si hace falta) y pásalo a mcp__jarvis__open_app. Nunca \
puedes pulsar enviar/llamar dentro de otra app ni leer chats o archivos \
de WhatsApp (iOS no lo permite a ninguna app) — como mucho dejas el chat \
abierto y lo dices. Para recomendar sitios (restaurantes, bares, \
tiendas...), busca opciones y reseñas reales por internet, decide y \
explica el motivo, y abre mcp__jarvis__open_app con target=maps o \
google_maps en ese sitio para que pueda ir — nunca lees reseñas dentro \
de la propia app Maps, la recomendación siempre sale de la búsqueda web. \
Si te envían una foto, o el usuario apunta la cámara y dice algo como "mira \
esto" o "¿qué ves?", analízala y reacciona con naturalidad y brevedad, como \
si la estuvieras viendo en el momento — porque la ves. Si junto a esa foto \
recibes fotos de referencia de la familia (cada una etiquetada con el \
nombre de quién es), compáralas con la nueva foto: si con razonable \
confianza reconoces a alguien, dirígete a él o ella por su nombre y usa lo \
que ya sepas de esa persona; si no estás seguro, no lo afirmes ni lo \
adivines — responde con naturalidad sin mencionar quién es. Con \
mcp__jarvis__clock_action puedes crear alarmas y temporizadores nuevos, \
pero nunca leer alarmas existentes, decir cuánto queda de un temporizador \
ni controlar el cronómetro — Apple no lo permite a ninguna app. Si no \
tienes herramienta para algo, dilo en vez de inventarlo. No tienes \
sistema de archivos ni terminal en este Mac: todo pasa por tus \
herramientas, que corren en el iPhone del usuario salvo la búsqueda web \
y el tiempo, que corren aquí.`;

type PendingCall = {
  resolve: (text: string) => void;
  timeout: NodeJS.Timeout;
};

const httpServer = createServer((_req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Jarvis server OK\n");
});

/**
 * The phone opens a fresh WebSocket per turn, and can disappear mid-turn
 * (app closed, network drop) — the Claude query itself keeps running to
 * completion regardless (it's not tied to the socket), so sending the
 * result back can fail on an already-closed connection. Returns false
 * instead of throwing so the caller can fall back to persisting the result
 * for later (see backgroundJobs.ts) rather than losing it.
 */
function trySend(ws: WebSocket, payload: Record<string, unknown>): boolean {
  if (ws.readyState !== ws.OPEN) return false;
  try {
    ws.send(JSON.stringify(payload));
    return true;
  } catch {
    return false;
  }
}

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
      // If the phone's already gone, just let the timeout above resolve
      // with the "didn't respond in time" fallback instead of throwing.
      trySend(ws, { type: "tool_call", id, name, input });
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

    if (msg.type === "check_pending") {
      // Sent once, right when the app opens (see JarvisServerClient.
      // checkPendingResult) — if a previous turn finished after the phone
      // had already disconnected, this is where Jarvis hands you the
      // answer instead of it being silently lost.
      const pendingResult = takePendingResult();
      if (pendingResult) {
        trySend(ws, { type: "pending_result", text: pendingResult });
      } else {
        trySend(ws, { type: "no_pending" });
      }
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

      // Photos the user attached (via the "te voy a enviar una foto" flow,
      // or the "mira esto" direct-camera glance) ride along as image content
      // blocks in the same turn, instead of a plain string prompt.
      const images: Array<{ media_type?: string; data?: string }> = Array.isArray(msg.images) ? msg.images : [];
      const validImages = images.filter(
        (img): img is { media_type: string; data: string } => typeof img.media_type === "string" && typeof img.data === "string"
      );

      // Reference photos of the family (server/family/*.jpg, see family.ts)
      // ride along first so Claude can compare them against whatever the
      // user just sent and try to recognize who's in frame.
      const familyPhotos = validImages.length > 0 ? loadFamilyReferencePhotos() : [];

      const prompt = validImages.length > 0
        ? (async function* () {
            yield {
              type: "user" as const,
              message: {
                role: "user" as const,
                content: [
                  ...(familyPhotos.length > 0
                    ? [{
                        type: "text" as const,
                        text: "Fotos de referencia de la familia, para que puedas reconocer a alguien en la foto de abajo si aparece (nombre de cada una entre paréntesis):"
                      }]
                    : []),
                  ...familyPhotos.flatMap((photo) => [
                    { type: "text" as const, text: `(${photo.name})` },
                    {
                      type: "image" as const,
                      source: { type: "base64" as const, media_type: photo.mediaType, data: photo.data }
                    }
                  ]),
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
              "mcp__jarvis__music_control",
              "mcp__jarvis__check_gmail",
              "mcp__jarvis__notes_content",
              "mcp__jarvis__clock_action",
              "mcp__jarvis__files_content",
              "mcp__jarvis__remember_fact"
            ],
            permissionMode: "bypassPermissions",
            allowDangerouslySkipPermissions: true,
            ...(sessionId ? { resume: sessionId } : {}),
            ...(CLAUDE_EXECUTABLE_PATH ? { pathToClaudeCodeExecutable: CLAUDE_EXECUTABLE_PATH, executable: "node" as const } : {})
          }
        });

        for await (const event of stream) {
          if (event.type === "result") {
            sessionId = event.session_id;
            saveSessionId(sessionId);
            if (event.subtype === "success") {
              // The query itself already ran to completion regardless of
              // whether the phone stuck around for it — if the socket's
              // gone, don't lose the answer, save it for next time the app
              // opens instead (see check_pending above).
              if (!trySend(ws, { type: "final_answer", text: event.result })) {
                savePendingResult(event.result);
              }
            } else {
              trySend(ws, {
                type: "error",
                message: `Jarvis no pudo terminar la respuesta (${event.subtype}).`
              });
            }
          }
        }
      } catch (error) {
        trySend(ws, {
          type: "error",
          message: error instanceof Error ? error.message : "Error desconocido"
        });
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
