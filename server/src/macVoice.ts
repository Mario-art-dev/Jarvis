import { spawn } from "node:child_process";
import { readFile, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

/**
 * Text-to-speech with macOS's built-in `say` command.
 *
 * This exists because the alternatives all have a way of failing: ElevenLabs
 * runs out of credits, and Piper's prebuilt macOS binary is broken upstream
 * (the release ships the executable without any of the .dylib files it links
 * against, so it cannot start on any Mac). `say` has neither problem — it is
 * part of macOS itself, needs no download, no account and no internet, and
 * has no quota. On an old Mac that can't be upgraded, "already installed" is
 * worth more than "best on paper".
 *
 * Quality depends on which voice is installed. The compact Spanish voices
 * that ship by default sound dated; the "enhanced" ones downloadable from
 * System Preferences sound much better and are picked up automatically
 * because they keep the same name (see scripts/setup-mac-voice.sh).
 */

/** Beyond this, synthesis is slow enough to be worse than the alternatives. */
const MAX_CHARS = 4000;
const TIMEOUT_MS = 30_000;

const MAC_VOICE = process.env.MAC_VOICE?.trim();
/** `say` defaults to 175 wpm, which sounds sluggish for short spoken replies. */
const MAC_VOICE_RATE = process.env.MAC_VOICE_RATE?.trim() || "185";

/**
 * Spanish voices in the order we'd rather have them, best first. Names come
 * from `say -v ?` and are stable across macOS versions.
 */
const PREFERRED_VOICES = [
  "Mónica", // es_ES, the default Spanish voice on Spanish Macs
  "Monica",
  "Jorge", // es_ES, male
  "Marisol",
  "Paulina", // es_MX
  "Juan",
  "Diego", // es_AR
  "Angelica",
  "Soledad"
];

let cachedVoice: string | null | undefined;

interface SayVoice {
  name: string;
  locale: string;
}

/**
 * When macOS has downloaded a better version of a voice it can appear as a
 * separate entry — "Jorge" and "Jorge (Mejorada)" side by side — and the
 * better one is exactly what someone went to the trouble of downloading.
 * Lower is better.
 */
function qualityRank(name: string): number {
  const n = name.toLowerCase();
  if (n.includes("premium")) return 0;
  if (n.includes("enhanced") || n.includes("mejorada")) return 1;
  return 2;
}

/** "Jorge (Mejorada)" -> "jorge", so a plain name matches every variant. */
function baseName(name: string): string {
  return name.replace(/\s*\(.*\)\s*$/, "").trim().toLowerCase();
}

/** Best-quality voice among those matching, or undefined if none do. */
function bestMatch(voices: SayVoice[], matches: (v: SayVoice) => boolean): SayVoice | undefined {
  return voices
    .filter(matches)
    .sort((a, b) => qualityRank(a.name) - qualityRank(b.name))[0];
}

function listVoices(): Promise<SayVoice[]> {
  return new Promise((resolve) => {
    const say = spawn("say", ["-v", "?"]);
    let out = "";
    say.stdout.on("data", (chunk) => {
      out += String(chunk);
    });
    say.on("error", () => resolve([]));
    say.on("close", () => {
      const voices: SayVoice[] = [];
      for (const line of out.split("\n")) {
        // "Mónica              es_ES    # ¡Hola! Me llamo Mónica."
        // Voice names can contain spaces ("Bad News"), so anchor on the locale.
        const match = line.match(/^(.+?)\s+([a-z]{2}[-_][A-Z]{2})\s+#/);
        if (match) voices.push({ name: match[1].trim(), locale: match[2] });
      }
      resolve(voices);
    });
  });
}

/**
 * Which voice `say` should use, or null if this machine has no Spanish voice
 * (or isn't a Mac at all). Resolved once and remembered — the answer can't
 * change while the server is running.
 */
async function resolveVoice(): Promise<string | null> {
  if (cachedVoice !== undefined) return cachedVoice;

  if (process.platform !== "darwin") {
    cachedVoice = null;
    return cachedVoice;
  }

  const voices = await listVoices();
  if (voices.length === 0) {
    cachedVoice = null;
    return cachedVoice;
  }

  // An explicit choice wins, but only if it's really installed — a typo in
  // .env shouldn't leave Jarvis mute. Asking for "Jorge" also accepts
  // "Jorge (Mejorada)": nobody downloads the better version and then means
  // the worse one.
  if (MAC_VOICE) {
    const chosen = bestMatch(voices, (v) => baseName(v.name) === baseName(MAC_VOICE));
    if (chosen) {
      cachedVoice = chosen.name;
      return cachedVoice;
    }
    console.warn(
      `MAC_VOICE="${MAC_VOICE}" no está instalada en este Mac; se usará la mejor voz en español disponible.`
    );
  }

  for (const preferred of PREFERRED_VOICES) {
    const found = bestMatch(voices, (v) => baseName(v.name) === preferred.toLowerCase());
    if (found) {
      cachedVoice = found.name;
      return cachedVoice;
    }
  }

  // Any Spanish voice beats falling through to no local voice at all.
  const anySpanish = bestMatch(voices, (v) => v.locale.toLowerCase().startsWith("es"));
  cachedVoice = anySpanish?.name ?? null;
  return cachedVoice;
}

/** Name of the voice `say` would use, for the startup log. Null if unusable. */
export async function macVoiceName(): Promise<string | null> {
  return resolveVoice();
}

/** Returns base64 WAV audio, or null if `say` isn't usable for any reason. */
export async function synthesizeWithSay(text: string): Promise<string | null> {
  const voice = await resolveVoice();
  if (!voice) return null;

  const clean = text.trim();
  if (!clean || clean.length > MAX_CHARS) return null;

  const id = randomUUID();
  const textPath = join(tmpdir(), `jarvis-say-${id}.txt`);
  const outputPath = join(tmpdir(), `jarvis-say-${id}.wav`);

  try {
    // Passing the text as a file rather than an argument: it avoids both the
    // command-line length limit on long replies and any quoting surprises
    // with accents or punctuation.
    await writeFile(textPath, clean, "utf8");
    await runSay(voice, textPath, outputPath);
    const audio = await readFile(outputPath);
    if (audio.length === 0) return null;
    return audio.toString("base64");
  } catch (error) {
    console.error("La voz del Mac no pudo generar el audio, se usará otra:", error);
    return null;
  } finally {
    await unlink(textPath).catch(() => {});
    await unlink(outputPath).catch(() => {});
  }
}

function runSay(voice: string, textPath: string, outputPath: string): Promise<void> {
  return new Promise((resolve, reject) => {
    // LEI16@22050 is plain 16-bit PCM: what AVAudioPlayer on the phone reads
    // without any conversion. Without --data-format, `say` writes 32-bit
    // float, which iOS refuses to play.
    const say = spawn("say", [
      "-v",
      voice,
      "-r",
      MAC_VOICE_RATE,
      "-f",
      textPath,
      "-o",
      outputPath,
      "--data-format=LEI16@22050"
    ]);

    let stderr = "";
    say.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });

    // Don't let a hung process hold up the whole reply — the phone is
    // waiting on this before it can say anything.
    const timeout = setTimeout(() => {
      say.kill("SIGKILL");
      reject(new Error(`La voz del Mac tardó más de ${TIMEOUT_MS / 1000}s`));
    }, TIMEOUT_MS);

    say.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });

    say.on("close", (code) => {
      clearTimeout(timeout);
      if (code === 0) resolve();
      else reject(new Error(`say salió con código ${code}: ${stderr.trim()}`));
    });
  });
}
