# OIDC Authentication in Arbor

> Updated: 2026-06-01
> Audience: operators setting up Arbor for the first time, or adding human authentication to an existing install.

This guide explains how Arbor uses OpenID Connect (OIDC) for human identity, how to wire any compliant OIDC provider into Arbor, and what to do after your first login so the dashboard is actually usable.

---

## 1. Why Arbor uses OIDC

Arbor's security model is capability-based: every privileged action in the dashboard, MCP gateway, and consensus system requires the caller to hold a specific capability. To grant capabilities to a *human*, Arbor needs a verified, stable identifier for that person.

OIDC gives Arbor:

1. **A verified identity per login.** The provider tells Arbor "this request came from `sub=12345` at `iss=https://accounts.google.com`." Arbor doesn't store passwords or trust self-asserted ids.
2. **A stable `human_<hash>` agent id.** Arbor derives it deterministically as `"human_" <> sha256("#{iss}:#{sub}")[:40]`, so the same person logging in from the same provider always gets the same id. That id is what `Arbor.Security.assign_role/2` and `Arbor.Security.grant/1` target.
3. **No shared accounts.** Each human has their own identity, their own capability set, and their own audit trail. Suspending or revoking an identity in Arbor's `Identity.Registry` immediately stops it from authorizing anything.
4. **Provider neutrality.** Arbor doesn't ship an identity database. You bring whatever OIDC provider you already use (or self-host one — Zitadel is the worked example below).

---

## 2. Prerequisites

You need an OIDC provider that supports:

- **Authorization Code + PKCE** (for the browser-based dashboard login at `/auth/login`).
- **OIDC Discovery** (the well-known endpoint at `{issuer}/.well-known/openid-configuration`). Arbor reads the authorization, token, and userinfo endpoints from there.
- **Device Authorization Grant** (optional — only needed if you want the CLI device flow for `mix arbor.orchestrate`-style commands).

Any of these work out of the box: **Zitadel**, **Keycloak**, **Authentik**, **Google Identity**, **GitHub** (via their OIDC flow), **Auth0**, **Okta**.

You'll need three pieces of information from the provider after you set up an application:

| Value | Where it comes from |
|---|---|
| **Issuer URL** | Provider's base OIDC URL (e.g. `https://accounts.google.com`, `http://localhost:8080`) |
| **Client ID** | Generated when you create the application in the provider's console |
| **Client Secret** | Generated alongside the client ID (omit if you use PKCE-only) |

And one configuration decision on the provider side:

- **Redirect URI** must be set to `http://localhost:4001/auth/callback` for local dev (replace host/port for prod).
- **Post-logout Redirect URI**: `http://localhost:4001` (same host/port logic).

---

## 3. Configuring Arbor

Arbor reads OIDC config from environment variables at runtime (see `config/runtime.exs`). Put these in your `.env` file at the project root:

```bash
# Required
OIDC_ISSUER=https://your-provider.example.com
OIDC_CLIENT_ID=<from-your-provider>

# Optional — omit if you use PKCE-only (no client secret)
OIDC_CLIENT_SECRET=<from-your-provider>

# Optional — comma-separated. Defaults to "openid,email,profile"
# OIDC_SCOPES=openid,email,profile,groups

# Optional — disable device flow if you don't need CLI auth
# OIDC_DEVICE_FLOW=false

# Optional — separate client ID for the CLI device flow
# Useful when your provider distinguishes web apps from native apps
# (e.g. Zitadel's "Web" vs "Native" application types). Defaults to OIDC_CLIENT_ID.
# OIDC_DEVICE_CLIENT_ID=<native-app-client-id>
```

When **both** `OIDC_ISSUER` and `OIDC_CLIENT_ID` are present, Arbor activates OIDC. Either missing → OIDC is disabled.

### Production posture (P0-1)

`runtime.exs` sets `:arbor_dashboard, require_auth: true` in `:prod`. If `require_auth` is true but OIDC isn't configured, the dashboard halts with **503 Service Unavailable** rather than falling through to open access. You **must** configure OIDC for any production deployment, or the dashboard will refuse to serve traffic.

Dev / test environments leave `require_auth` unset, so the dashboard runs open if you haven't wired OIDC yet.

---

## 4. Worked example: self-hosted Zitadel

If you want a turnkey self-hosted OIDC provider, Arbor ships a Docker compose stack for **Zitadel** under `docker/zitadel/`. The full per-step procedure (compose up, creating the Dashboard + CLI applications in Zitadel's console, populating `.env`) is in [`docker/zitadel/README.md`](../docker/zitadel/README.md).

In summary:

1. `cd docker/zitadel && docker compose up -d --wait` — Zitadel is reachable at `http://localhost:8080`.
2. Log in to the Zitadel console (`zitadel-admin@zitadel.localhost` / `Password1!`) and create a project + a **Web** application (Auth Code + PKCE) and optionally a **Native** application (for the CLI device flow).
3. Set the redirect URIs:
   - Web app → `http://localhost:4001/auth/callback`
   - Post-logout → `http://localhost:4001`
4. Copy the client IDs into your Arbor `.env`:
   ```bash
   OIDC_ISSUER=http://localhost:8080
   OIDC_CLIENT_ID=<dashboard-client-id>
   OIDC_CLIENT_SECRET=<dashboard-client-secret>   # omit for PKCE
   OIDC_DEVICE_CLIENT_ID=<cli-client-id>
   ```
5. Restart Arbor.

That same .env block — with a different `OIDC_ISSUER` and client IDs — works for any other compliant provider.

---

## 5. Other providers (minimal config deltas)

The Arbor side is unchanged across providers; only the issuer URL and client setup differ.

### Google Identity

```bash
OIDC_ISSUER=https://accounts.google.com
OIDC_CLIENT_ID=<from-Google-Cloud-Console>
OIDC_CLIENT_SECRET=<from-Google-Cloud-Console>
```

Create the OAuth 2.0 client in Google Cloud Console (APIs & Services → Credentials → Create credentials → OAuth client ID → Web application). Add `http://localhost:4001/auth/callback` to "Authorized redirect URIs."

### Keycloak

```bash
OIDC_ISSUER=https://your-keycloak.example.com/realms/<realm-name>
OIDC_CLIENT_ID=<from-Keycloak-Clients>
OIDC_CLIENT_SECRET=<from-Keycloak-Clients>  # if confidential client
```

Create a client in your realm; set "Valid Redirect URIs" to `http://localhost:4001/auth/callback`. Use a confidential client if you want a secret, or a public client with PKCE if you don't.

### Authentik

```bash
OIDC_ISSUER=https://your-authentik.example.com/application/o/<app-slug>/
OIDC_CLIENT_ID=<from-Authentik>
OIDC_CLIENT_SECRET=<from-Authentik>
```

The issuer URL trailing slash matters for Authentik's discovery.

### GitHub

GitHub's OIDC is more limited (no full discovery, no device flow), so the integration is rougher. If you need a turnkey setup, prefer Zitadel, Keycloak, or Authentik.

---

## 6. The first login

Once OIDC is configured and Arbor is running:

1. Visit `http://localhost:4001` — the dashboard plug (`Arbor.Dashboard.OidcAuth`) sees no session and redirects to `/auth/login`.
2. `/auth/login` redirects to your provider's authorization endpoint with a PKCE challenge.
3. You authenticate at the provider.
4. The provider redirects back to `/auth/callback` with a code.
5. Arbor exchanges the code for tokens, validates them, and:
   - Derives your `human_id` as `"human_" <> sha256("#{iss}:#{sub}")[:40]`.
   - Registers your identity in `Arbor.Security.Identity.Registry` (or loads it if it already exists).
   - Calls `Arbor.Security.assign_role(human_id, :viewer)` — the new least-privilege default (M1).
   - Grants the ambient `arbor://signals/subscribe/security` capability so security signals reach your dashboard.
6. You're redirected to the dashboard with `current_agent_id` set in your session.

### Finding your `human_id` after login

The simplest way is to grep the Arbor log for "Authenticated agent" — the gateway's signed-request auth and the dashboard's OIDC plug both emit your `human_<hash>` on every authenticated request.

Or from `iex`:

```elixir
# List recently-registered human identities
Arbor.Security.Identity.Registry.list()
|> Enum.filter(&String.starts_with?(&1, "human_"))
```

---

## 7. Bootstrap: granting yourself usable capabilities

By default the `:viewer` role you got at login only carries `arbor://signals/subscribe/security`. That's deliberate — it's the least-privilege fallback so a fresh OIDC integration doesn't accidentally hand admin to every user. To actually use the dashboard (approve proposals, run actions, browse memory), you need to be granted more capabilities.

There are three ways to do this:

### Option A — Full admin (simplest for single-operator deployments)

```elixir
# In iex:
Arbor.Security.assign_role("human_<your_hash>", :admin)
```

The built-in `:admin` role grants `arbor://**` (wildcard), which matches every Arbor capability URI. One call, full access.

### Option B — Scoped dev_admin (cleaner for multi-developer dev)

In `config/dev.exs`:

```elixir
config :arbor_security, :enable_dev_admin_role, true
```

Then:

```elixir
Arbor.Security.assign_role("human_<your_hash>", :dev_admin)
```

The `:dev_admin` role bundles the three capabilities that previously auto-granted on dashboard mount (`arbor://consensus/admin`, `arbor://trust/auto_promote/**`, `arbor://signals/subscribe/security`). It's narrower than `:admin` and never registered in `:prod` regardless of the flag.

### Option C — Custom role definitions (production)

Define exactly what each role grants in your `config/runtime.exs`:

```elixir
config :arbor_security,
  roles: %{
    operator: [
      "arbor://memory/read/**",
      "arbor://signals/subscribe/security",
      "arbor://status/**"
    ],
    proposer: [
      "arbor://consensus/propose/code_modification",
      "arbor://memory/read/**"
    ]
  }
```

Then `Arbor.Security.assign_role(human_id, :operator)` etc. Custom roles override built-ins of the same name.

You can also change the default role assigned to new OIDC logins:

```elixir
config :arbor_security, :default_human_role, :operator
```

---

## 8. CLI authentication (device flow)

If `OIDC_DEVICE_FLOW=true` (the default), CLI tools that need to authenticate as a human (e.g. `mix arbor.orchestrate` invoked outside a browser session) use the OAuth 2.0 Device Authorization Grant.

Tokens are cached at `~/.arbor/identity/oidc_tokens.enc` (encrypted at rest with the master key). Cached tokens auto-refresh while the refresh token is valid; expired tokens trigger a fresh device flow.

To force a re-login from the CLI:

```bash
rm ~/.arbor/identity/oidc_tokens.enc
```

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Dashboard returns **503** with "Dashboard authentication required but no OIDC provider configured" | `require_auth: true` (production default) but `OIDC_ISSUER` / `OIDC_CLIENT_ID` not set | Set both env vars and restart. |
| Dashboard returns **404** at `/auth/login` | OIDC not configured (handler is in the no-OIDC branch) | Same as above. |
| Provider rejects the redirect with "redirect_uri mismatch" | The provider's configured redirect URI doesn't match `http://localhost:4001/auth/callback` exactly (scheme, host, port, path must match) | Update the provider's app config. |
| Logged in successfully but every dashboard button fails with "Unauthorized" | Default role is `:viewer` and you haven't run the bootstrap from §7 | Run `Arbor.Security.assign_role(your_human_id, :admin)`. |
| Logged in but `current_agent_id` is missing from socket assigns | The OidcAuth plug isn't running for the route (e.g. you removed it from the endpoint, or you're hitting an MCP endpoint that uses signed-request auth instead) | Check `apps/arbor_dashboard/lib/arbor_dashboard/endpoint.ex:7`. |
| "Authenticated agent" log shows the correct `human_id` but it doesn't match the one I tried to `assign_role` to | Stale typo. Derive deterministically: `human_id = "human_" <> sha256("#{iss}:#{sub}")[:40]`. Re-grep the logs for the exact hash from your most recent login. |
| Identity gets created but immediately rejected with `:identity_suspended` | Someone (or a previous test) suspended the identity in `Arbor.Security.Identity.Registry`. After H5, suspended identities deny regardless of capability presence. | `Arbor.Security.Identity.Registry.resume(your_human_id)` from iex. |
| Identity status looks correct but `Arbor.Security.authorize/4` still denies | The `arbor_security` strict-mode flags are flipped in your environment. Check `config :arbor_security, :strict_identity_mode` and the per-facade `:strict_facade_mode` keys. | Either grant the missing cap, or relax the flags in dev. |

---

## 10. Related references

- [`docker/zitadel/README.md`](../docker/zitadel/README.md) — full Zitadel docker-compose walkthrough.
- [`config/runtime.exs`](../config/runtime.exs) — authoritative source for every OIDC env var Arbor reads.
- [`docs/arbor-security-design.md`](arbor-security-design.md) — the broader security model (capabilities, trust tiers, authorization pipeline).
- The `assign_role(:admin)` / `:dev_admin` bootstrap above is the durable home for that operator guidance. It originated as a cheat-sheet in `SECURITY_REMEDIATION_BREAKAGE.md`, which was archived out of the repo root on 2026-06-24 once its `security/p0-h-remediation` branch merged; see git history (or the local `.arbor/security-history/` archive) for the per-fix restoration notes.
