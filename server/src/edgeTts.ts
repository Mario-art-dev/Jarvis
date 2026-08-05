import { webcrypto } from "node:crypto";
import { MsEdgeTTS, OUTPUT_FORMAT } from "msedge-tts";

// msedge-tts assumes the Web Crypto API is available as the global `crypto`,
// which Node only provides unflagged from v19 onward. An older Node — exactly
// what an old Mac kept around for compatibility is likely to have — throws
// "crypto is not defined" the moment this tries to synthesise anything.
// Polyfilling it here fixes that for any Node version without requiring
// anyone to upgrade Node just for the voice.
if (!(globalThis as { crypto?: unknown }).crypto) {
  (globalThis as { crypto?: unknown }).crypto = webcrypto;
}

/**
 * Text-to-speech with Microsoft Edge's "Read aloud" voices, via the same
 * WebSocket endpoint the Edge browser itself uses. Free, no account, no API
 * key, no billing to enable — and the neural voices sound properly human,
 * closer to ElevenLabs than to the Mac's or the iPhone's own voice.
 *
 * The tradeoff for that: it's not an official, supported API. The `msedge-tts`
 * package (https://github.com/Migushthe2nd/MsEdgeTTS) reverse-engineers what
 * Edge does and keeps up with Microsoft's changes, but it could break without
 * warning if Microsoft locks it down harder. That's exactly why this returns
 * null on any failure instead of throwing: a bad month for this trick must
 * never mean a mute assistant, only one that quietly speaks with the next
 * voice in line (the Mac's, then ElevenLabs, then the iPhone's).
 *
 * Needs internet, same as ElevenLabs — unlike the Mac's own voice, which
 * works with none.
 */

/** Male, Spain — matches the masculine voice picked for the Mac and iPhone. */
const DEFAULT_VOICE = "es-ES-AlvaroNeural";
const EDGE_TTS_VOICE = process.env.EDGE_TTS_VOICE?.trim() || DEFAULT_VOICE;
const DISABLED = process.env.EDGE_TTS_DISABLED === "1";

/** Beyond this, synthesis is slow enough to be worse than the alternatives. */
const MAX_CHARS = 4000;
const TIMEOUT_MS = 15_000;

export function isEdgeTtsEnabled(): boolean {
  return !DISABLED;
}

export function edgeTtsVoiceName(): string {
  return EDGE_TTS_VOICE;
}

/** Returns base64 MP3 audio, or null if Edge TTS isn't usable for any reason. */
export async function synthesizeWithEdgeTts(text: string): Promise<string | null> {
  if (DISABLED) return null;

  const clean = text.trim();
  if (!clean || clean.length > MAX_CHARS) return null;

  const tts = new MsEdgeTTS();
  try {
    const audio = await withTimeout(runEdgeTts(tts, clean), TIMEOUT_MS);
    return audio.toString("base64");
  } catch (error) {
    console.error("Edge TTS no pudo generar el audio, se usará otra voz:", error);
    return null;
  } finally {
    tts.close();
  }
}

async function runEdgeTts(tts: MsEdgeTTS, text: string): Promise<Buffer> {
  await tts.setMetadata(EDGE_TTS_VOICE, OUTPUT_FORMAT.AUDIO_24KHZ_48KBITRATE_MONO_MP3);
  const { audioStream } = tts.toStream(text);

  const chunks: Buffer[] = [];
  for await (const chunk of audioStream) {
    chunks.push(chunk as Buffer);
  }
  const audio = Buffer.concat(chunks);
  if (audio.length === 0) throw new Error("Edge TTS devolvió audio vacío");
  return audio;
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Edge TTS tardó más de ${ms / 1000}s`)), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}
