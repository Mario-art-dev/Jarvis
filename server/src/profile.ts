import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

/**
 * Durable facts about the user (family, preferences, basics) that should
 * survive independently of the conversation session — even if that session
 * ever gets reset or grows so long it gets auto-summarized, these stay.
 * Deliberately a short plain-text list, not the full transcript, so
 * re-reading it every turn stays cheap.
 */
const __dirname = dirname(fileURLToPath(import.meta.url));
const PROFILE_FILE = join(__dirname, "..", ".jarvis-profile.md");

export function loadProfile(): string {
  try {
    return readFileSync(PROFILE_FILE, "utf8").trim();
  } catch {
    return "";
  }
}

export function rememberFact(fact: string): string {
  const clean = fact.trim();
  if (!clean) return "No me has dicho qué recordar.";
  const line = `- ${clean}\n`;
  try {
    const existing = existsSync(PROFILE_FILE) ? readFileSync(PROFILE_FILE, "utf8") : "";
    writeFileSync(PROFILE_FILE, existing + line, "utf8");
    return "Hecho, lo recordaré siempre a partir de ahora.";
  } catch (error) {
    console.error("No pude guardar el dato en el perfil de Jarvis:", error);
    return "No he podido guardar eso.";
  }
}
