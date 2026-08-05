import { readFileSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

/**
 * If the phone disconnects (app closed, network drop, silenced) before a
 * turn finishes, the Claude Agent SDK query itself keeps running to
 * completion on the Mac regardless — only the attempt to `ws.send()` the
 * answer back fails, since that specific socket is gone. Instead of losing
 * the result, it lands here, and the next time the phone connects (opening
 * the app again), Jarvis delivers it as if picking the conversation back up.
 *
 * Deliberately just one slot, not a queue: this is a single-user assistant
 * with one phone talking to it, so "the answer to the last thing you asked
 * before disconnecting" is all there ever needs to be. A second unfinished
 * turn overwrites the first rather than piling up stale answers.
 */
const __dirname = dirname(fileURLToPath(import.meta.url));
const PENDING_FILE = join(__dirname, "..", ".jarvis-pending-result.json");

type PendingResult = {
  text: string;
  createdAt: string;
};

export function savePendingResult(text: string) {
  const payload: PendingResult = { text, createdAt: new Date().toISOString() };
  try {
    writeFileSync(PENDING_FILE, JSON.stringify(payload), "utf8");
  } catch (error) {
    console.error("No pude guardar el resultado pendiente:", error);
  }
}

/** Reads and clears the pending result, if any — delivered at most once. */
export function takePendingResult(): string | null {
  if (!existsSync(PENDING_FILE)) return null;
  try {
    const raw = readFileSync(PENDING_FILE, "utf8");
    const payload = JSON.parse(raw) as PendingResult;
    clearPendingResult();
    return payload.text || null;
  } catch (error) {
    console.error("No pude leer el resultado pendiente:", error);
    clearPendingResult();
    return null;
  }
}

function clearPendingResult() {
  try {
    if (existsSync(PENDING_FILE)) unlinkSync(PENDING_FILE);
  } catch {
    // best-effort cleanup, not worth surfacing
  }
}
