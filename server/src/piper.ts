import { spawn } from "node:child_process";
import { readFile, unlink } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

/**
 * Text-to-speech with Piper (https://github.com/rhasspy/piper), running
 * locally on this Mac: free, unlimited, no account, no internet.
 *
 * Entirely optional. Configure PIPER_PATH and PIPER_VOICE in server/.env
 * (see scripts/install-piper.sh) and Jarvis speaks with it; leave them unset,
 * or have anything go wrong, and this returns null so the phone falls back to
 * ElevenLabs and then to the iPhone's own voice. That fallback matters more
 * than usual here: the Mac this runs on is old enough that a prebuilt binary
 * refusing to launch is a real possibility, and a broken voice engine must
 * never mean a mute assistant.
 */
const PIPER_PATH = process.env.PIPER_PATH;
const PIPER_VOICE = process.env.PIPER_VOICE;

/** Beyond this, synthesis is slow enough to be worse than the alternatives. */
const MAX_CHARS = 4000;
const TIMEOUT_MS = 30_000;

export function isPiperConfigured(): boolean {
  return Boolean(PIPER_PATH && PIPER_VOICE && existsSync(PIPER_PATH) && existsSync(PIPER_VOICE));
}

/** Returns base64 WAV audio, or null if Piper isn't usable for any reason. */
export async function synthesizeWithPiper(text: string): Promise<string | null> {
  if (!isPiperConfigured()) return null;

  const clean = text.trim();
  if (!clean || clean.length > MAX_CHARS) return null;

  const outputPath = join(tmpdir(), `jarvis-piper-${randomUUID()}.wav`);

  try {
    await runPiper(clean, outputPath);
    const audio = await readFile(outputPath);
    return audio.toString("base64");
  } catch (error) {
    console.error("Piper no pudo generar el audio, se usará otra voz:", error);
    return null;
  } finally {
    await unlink(outputPath).catch(() => {});
  }
}

function runPiper(text: string, outputPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const piper = spawn(PIPER_PATH!, ["--model", PIPER_VOICE!, "--output_file", outputPath]);

    let stderr = "";
    piper.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });

    // Don't let a hung process hold up the whole reply — the phone is
    // waiting on this before it can say anything.
    const timeout = setTimeout(() => {
      piper.kill("SIGKILL");
      reject(new Error(`Piper tardó más de ${TIMEOUT_MS / 1000}s`));
    }, TIMEOUT_MS);

    piper.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });

    piper.on("close", (code) => {
      clearTimeout(timeout);
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`Piper salió con código ${code}: ${stderr.trim()}`));
      }
    });

    piper.stdin.write(text);
    piper.stdin.end();
  });
}
