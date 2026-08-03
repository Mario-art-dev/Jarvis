import { ImapFlow } from "imapflow";

/**
 * Reads Gmail via plain IMAP using a Gmail "App Password" — no Google Cloud
 * project, no OAuth consent screen. Requires 2-Step Verification enabled on
 * the account and an app password generated at
 * https://myaccount.google.com/apppasswords, stored as GMAIL_ADDRESS /
 * GMAIL_APP_PASSWORD in server/.env. Read-only: only ever fetches envelope
 * data (subject/sender/date), never modifies anything in the mailbox.
 */
export async function checkGmail(limit = 5): Promise<string> {
  const address = process.env.GMAIL_ADDRESS;
  const appPassword = process.env.GMAIL_APP_PASSWORD;
  if (!address || !appPassword) {
    return "No tengo configurado el acceso a Gmail todavía (falta GMAIL_ADDRESS/GMAIL_APP_PASSWORD en el servidor).";
  }

  const client = new ImapFlow({
    host: "imap.gmail.com",
    port: 993,
    secure: true,
    auth: { user: address, pass: appPassword },
    logger: false
  });

  try {
    await client.connect();
  } catch (error) {
    return `No pude conectar con Gmail: ${error instanceof Error ? error.message : "error desconocido"}.`;
  }

  try {
    const lock = await client.getMailboxLock("INBOX");
    try {
      const status = await client.status("INBOX", { unseen: true });
      const unseenCount = status.unseen ?? 0;

      if (unseenCount === 0) {
        return "No tienes correos sin leer en Gmail.";
      }

      const lines: string[] = [];
      for await (const message of client.fetch({ seen: false }, { envelope: true })) {
        const from = message.envelope?.from?.[0];
        const fromLabel = from?.name || from?.address || "remitente desconocido";
        const subject = message.envelope?.subject || "(sin asunto)";
        lines.push(`de ${fromLabel}: "${subject}"`);
        if (lines.length >= limit) break;
      }

      const summary = lines.join("; ");
      return `Tienes ${unseenCount} correos sin leer en Gmail. Los más recientes: ${summary}.`;
    } finally {
      lock.release();
    }
  } finally {
    await client.logout().catch(() => {});
  }
}
