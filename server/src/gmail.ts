import { ImapFlow } from "imapflow";

/**
 * Reads Gmail via plain IMAP using a Gmail "App Password" — no Google Cloud
 * project, no OAuth consent screen. Requires 2-Step Verification enabled on
 * the account and an app password generated at
 * https://myaccount.google.com/apppasswords. Read-only: only ever fetches
 * envelope data (subject/sender/date), never modifies anything.
 *
 * Supports multiple accounts via numbered env vars in server/.env:
 *   GMAIL_1_LABEL=personal
 *   GMAIL_1_ADDRESS=correo1@gmail.com
 *   GMAIL_1_APP_PASSWORD=xxxxxxxxxxxxxxxx
 *   GMAIL_2_LABEL=trabajo
 *   GMAIL_2_ADDRESS=correo2@gmail.com
 *   GMAIL_2_APP_PASSWORD=yyyyyyyyyyyyyyyy
 * (up to GMAIL_9_*). Any slot missing ADDRESS/APP_PASSWORD is skipped.
 */
type GmailAccount = { label: string; address: string; appPassword: string };

function configuredAccounts(): GmailAccount[] {
  const accounts: GmailAccount[] = [];
  for (let i = 1; i <= 9; i++) {
    const address = process.env[`GMAIL_${i}_ADDRESS`];
    const appPassword = process.env[`GMAIL_${i}_APP_PASSWORD`];
    if (!address || !appPassword) continue;
    const label = process.env[`GMAIL_${i}_LABEL`] || address;
    accounts.push({ label, address, appPassword });
  }
  return accounts;
}

function matchAccounts(accounts: GmailAccount[], query?: string): GmailAccount[] {
  if (!query || !query.trim()) return accounts;
  const needle = query.trim().toLowerCase();
  const matches = accounts.filter(
    (a) => a.label.toLowerCase().includes(needle) || a.address.toLowerCase().includes(needle)
  );
  return matches.length > 0 ? matches : accounts;
}

async function checkOneAccount(account: GmailAccount, limit: number): Promise<string> {
  const client = new ImapFlow({
    host: "imap.gmail.com",
    port: 993,
    secure: true,
    auth: { user: account.address, pass: account.appPassword },
    logger: false
  });

  try {
    await client.connect();
  } catch (error) {
    return `${account.label}: no pude conectar (${error instanceof Error ? error.message : "error desconocido"}).`;
  }

  try {
    const lock = await client.getMailboxLock("INBOX");
    try {
      const status = await client.status("INBOX", { unseen: true });
      const unseenCount = status.unseen ?? 0;

      if (unseenCount === 0) {
        return `${account.label}: sin correos sin leer.`;
      }

      const lines: string[] = [];
      for await (const message of client.fetch({ seen: false }, { envelope: true })) {
        const from = message.envelope?.from?.[0];
        const fromLabel = from?.name || from?.address || "remitente desconocido";
        const subject = message.envelope?.subject || "(sin asunto)";
        lines.push(`de ${fromLabel}: "${subject}"`);
        if (lines.length >= limit) break;
      }

      return `${account.label}: ${unseenCount} sin leer. Los más recientes: ${lines.join("; ")}.`;
    } finally {
      lock.release();
    }
  } finally {
    await client.logout().catch(() => {});
  }
}

export async function checkGmail(account?: string, limit = 5): Promise<string> {
  const accounts = configuredAccounts();
  if (accounts.length === 0) {
    return "No tengo configurada ninguna cuenta de Gmail todavía (falta GMAIL_1_ADDRESS/GMAIL_1_APP_PASSWORD en el servidor).";
  }

  const targets = matchAccounts(accounts, account);
  const results = await Promise.all(targets.map((a) => checkOneAccount(a, limit)));
  return results.join(" | ");
}
