// Minimal Raindrop OAuth token-exchange/refresh relay.
//
// Raindrop's authorization-code and refresh-token grants both require a
// client_secret in the request body
// (https://developer.raindrop.io/v1/authentication/token) and document no
// PKCE alternative. A secret embedded in a distributed desktop app is not
// protected — any user can extract it from the binary — so this Worker is
// the "minimal OAuth relay" described in docs/architecture.md: it proxies
// only the token exchange and refresh calls, injecting the secret
// server-side from a Worker secret binding.
//
// It never logs or persists a token, an authorization code, article
// content, or a request body. It holds no state of its own.

const RAINDROP_TOKEN_URL = "https://raindrop.io/oauth/access_token";

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const url = new URL(request.url);
    let body;
    try {
      body = await request.json();
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    let payload;
    if (url.pathname === "/raindrop/token") {
      if (typeof body.code !== "string" || typeof body.redirect_uri !== "string") {
        return new Response("Missing code or redirect_uri", { status: 400 });
      }
      payload = {
        grant_type: "authorization_code",
        code: body.code,
        redirect_uri: body.redirect_uri,
        client_id: env.RAINDROP_CLIENT_ID,
        client_secret: env.RAINDROP_CLIENT_SECRET
      };
    } else if (url.pathname === "/raindrop/refresh") {
      if (typeof body.refresh_token !== "string") {
        return new Response("Missing refresh_token", { status: 400 });
      }
      payload = {
        grant_type: "refresh_token",
        refresh_token: body.refresh_token,
        client_id: env.RAINDROP_CLIENT_ID,
        client_secret: env.RAINDROP_CLIENT_SECRET
      };
    } else {
      return new Response("Not found", { status: 404 });
    }

    let upstream;
    try {
      upstream = await fetch(RAINDROP_TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      });
    } catch {
      return new Response("Upstream unreachable", { status: 502 });
    }

    // Passed straight through, unlogged — the client's own error handling
    // (RaindropOAuthClient.OAuthError.relay) reads this body directly.
    const text = await upstream.text();
    return new Response(text, {
      status: upstream.status,
      headers: { "Content-Type": "application/json" }
    });
  }
};
