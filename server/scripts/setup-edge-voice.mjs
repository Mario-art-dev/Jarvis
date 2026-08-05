#!/usr/bin/env node
// Elige la voz de Edge TTS (gratis, sin cuenta, la misma que usa el propio
// navegador Edge para "Leer en voz alta") que usará Jarvis.
//
// Uso:
//   node scripts/setup-edge-voice.mjs --list        # ver todas las voces en español
//   node scripts/setup-edge-voice.mjs                # escuchar y fijar la de por defecto (Álvaro)
//   node scripts/setup-edge-voice.mjs es-ES-ElviraNeural   # escuchar y fijar esa
//
// Necesita internet: esta voz se genera en los servidores de Microsoft, a
// diferencia de la del propio Mac. Si algún día deja de funcionar (ver
// server/src/edgeTts.ts), Jarvis sigue hablando con la voz del Mac sin que
// tengas que tocar nada.

import { MsEdgeTTS, OUTPUT_FORMAT } from "msedge-tts";
import { writeFile, unlink, readFile } from "node:fs/promises";
import { existsSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = dirname(SCRIPT_DIR);
const ENV_FILE = join(SERVER_DIR, ".env");
const ENV_EXAMPLE = join(SERVER_DIR, ".env.example");

const DEFAULT_VOICE = "es-ES-AlvaroNeural";

function playFile(path) {
  return new Promise((resolve) => {
    // afplay viene con macOS, no hace falta instalar nada.
    const player = spawn("afplay", [path]);
    player.on("error", () => resolve());
    player.on("close", () => resolve());
  });
}

async function listSpanishVoices() {
  const tts = new MsEdgeTTS();
  const all = await tts.getVoices();
  return all.filter((v) => v.Locale.toLowerCase().startsWith("es"));
}

async function synthesizeToFile(voiceName, text, outPath) {
  const tts = new MsEdgeTTS();
  try {
    await tts.setMetadata(voiceName, OUTPUT_FORMAT.AUDIO_24KHZ_48KBITRATE_MONO_MP3);
    const { audioStream } = tts.toStream(text);
    const chunks = [];
    for await (const chunk of audioStream) chunks.push(chunk);
    await writeFile(outPath, Buffer.concat(chunks));
  } finally {
    tts.close();
  }
}

function setEnvVar(key, value) {
  if (!existsSync(ENV_FILE)) copyFileSync(ENV_EXAMPLE, ENV_FILE);
  return readFile(ENV_FILE, "utf8").then((content) => {
    const line = `${key}=${value}`;
    const pattern = new RegExp(`^${key}=.*$`, "m");
    const next = pattern.test(content) ? content.replace(pattern, line) : `${content}\n${line}\n`;
    return writeFile(ENV_FILE, next);
  });
}

const args = process.argv.slice(2);

if (args.includes("--list") || args.includes("-l")) {
  console.log("Consultando las voces de Microsoft Edge en español...\n");
  let voices;
  try {
    voices = await listSpanishVoices();
  } catch (error) {
    console.error("ERROR: no se ha podido contactar con Microsoft. ¿Hay internet?");
    console.error(String(error));
    process.exit(1);
  }
  for (const v of voices) {
    const gender = v.Gender === "Male" ? "hombre" : v.Gender === "Female" ? "mujer" : v.Gender;
    console.log(`  ${v.ShortName.padEnd(24)} ${v.Locale.padEnd(8)} (${gender})`);
  }
  console.log("\nPara escuchar una y dejarla fija:");
  console.log("  node scripts/setup-edge-voice.mjs es-ES-ElviraNeural");
  process.exit(0);
}

const requested = args[0] || DEFAULT_VOICE;

console.log(`==> Probando "${requested}"...`);
const testFile = join(tmpdir(), `jarvis-edge-tts-${Date.now()}.mp3`);
try {
  await synthesizeToFile(requested, "Buenas señor, ¿en qué puedo ayudarle?", testFile);
} catch (error) {
  console.error(`\nERROR: no se ha podido generar audio con "${requested}".`);
  console.error(String(error));
  console.error("\n¿Nombre de voz correcto? Compruébalo con: node scripts/setup-edge-voice.mjs --list");
  console.error("No se ha cambiado nada: Jarvis sigue con la voz del Mac.");
  await unlink(testFile).catch(() => {});
  process.exit(1);
}

console.log("==> Reproduciendo...");
await playFile(testFile);
await unlink(testFile).catch(() => {});

await setEnvVar("EDGE_TTS_VOICE", requested);

console.log(`\n==> Listo. Jarvis usará "${requested}" (o la mejor disponible si esta falla).`);
console.log("    Reinicia el servidor (Ctrl+C y 'npm start' dentro de server/).");
