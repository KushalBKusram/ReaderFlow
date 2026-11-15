# Raindrop OAuth relay

This is the "minimal OAuth relay" named in `docs/architecture.md`. It exists
for one reason: Raindrop's token endpoint requires a `client_secret` in both
the authorization-code exchange and the refresh request
(https://developer.raindrop.io/v1/authentication/token), and documents no
PKCE alternative. A secret bundled in a distributed desktop app isn't
protected — anyone can extract it from the binary — so ReaderFlow Desktop
never holds it. This Worker does, as a Cloudflare Workers secret binding, and
proxies only the two token calls. It does not see, log, or store article
content, scripts, audio, or Nearby Sync data, and it holds no state of its
own — it is a pure request/response proxy.

## What it exposes

- `POST /raindrop/token` — body `{ "code": "...", "redirect_uri": "..." }`,
  forwards an `authorization_code` grant to Raindrop with the stored secret.
- `POST /raindrop/refresh` — body `{ "refresh_token": "..." }`, forwards a
  `refresh_token` grant the same way.

Both return Raindrop's token response unchanged (`access_token`,
`refresh_token`, `expires_in`, `token_type`) or its error body, with the
same HTTP status.

## One-time setup

1. Register ReaderFlow at <https://app.raindrop.io/settings/integrations>.
   Set its redirect URI to `readerflow://oauth/raindrop`. Note the client ID
   and client secret it gives you.
2. Install Cloudflare's CLI and sign in:
   ```bash
   npm install -g wrangler
   wrangler login
   ```
3. From this directory, set the two secrets (never commit these):
   ```bash
   wrangler secret put RAINDROP_CLIENT_ID
   wrangler secret put RAINDROP_CLIENT_SECRET
   ```
4. Deploy:
   ```bash
   wrangler deploy
   ```
   This prints the Worker's URL, e.g. `https://readerflow-raindrop-relay.<you>.workers.dev`.
5. In ReaderFlow's Raindrop settings sheet, enter the same client ID from
   step 1 and this Worker URL as the relay URL. The client ID is not a
   secret — it's visible in the sign-in URL regardless — only the client
   secret needs to stay out of the app, and it never leaves this Worker.

## Scope

This relay is the design for distributed builds. It was not deployed: the
prototype verified OAuth in a single-user personal mode that keeps the client
secret in the Keychain. Deploying it needs a Raindrop app registration and a
Cloudflare account. See `docs/findings.md`.
