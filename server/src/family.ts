import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, extname, basename } from "node:path";

/**
 * Reference photos for family recognition: drop one photo per person into
 * server/family/ named after them (e.g. "Laura.jpg", "Mario.jpg") and Claude
 * gets them alongside any photo the user sends, so it can try to recognize
 * who's in frame and personalize its reply. Read fresh on every request
 * (not cached) so adding/removing a photo takes effect immediately, no
 * server restart needed — the folder only ever holds a handful of files, so
 * the disk cost is negligible.
 */
const __dirname = dirname(fileURLToPath(import.meta.url));
const FAMILY_DIR = join(__dirname, "..", "family");

const MEDIA_TYPES: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp"
};

export type FamilyReferencePhoto = {
  name: string;
  mediaType: "image/jpeg" | "image/png" | "image/gif" | "image/webp";
  data: string;
};

export function loadFamilyReferencePhotos(): FamilyReferencePhoto[] {
  let files: string[];
  try {
    files = readdirSync(FAMILY_DIR);
  } catch {
    return [];
  }

  const photos: FamilyReferencePhoto[] = [];
  for (const file of files) {
    const ext = extname(file).toLowerCase();
    const mediaType = MEDIA_TYPES[ext];
    if (!mediaType) continue; // skips README.md, .gitkeep, etc.
    try {
      const data = readFileSync(join(FAMILY_DIR, file)).toString("base64");
      const name = basename(file, ext).replace(/[_-]+/g, " ").trim();
      if (!name) continue;
      photos.push({ name, mediaType: mediaType as FamilyReferencePhoto["mediaType"], data });
    } catch (error) {
      console.error(`No pude leer la foto de referencia ${file}:`, error);
    }
  }
  return photos;
}
