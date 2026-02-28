# Zitadel Identity Provider for Arbor

Self-hosted OIDC provider using [Zitadel](https://zitadel.com/) v4.
Provides human identity authentication for Arbor's dashboard and CLI.

## Quick Start

```bash
cd docker/zitadel
docker compose up -d --wait
```

Zitadel will be available at **http://localhost:8080**.

Default admin: `zitadel-admin@zitadel.localhost` / `Password1!`

## Create OIDC Applications

Open the Zitadel console at http://localhost:8080/ui/console and:

### 1. Create a Project

Navigate to **Projects** > **Create New Project** (e.g., "Arbor").

### 2. Web Application (Dashboard — Auth Code + PKCE)

In your project, **New** > **Application**:

- Name: `Arbor Dashboard`
- Type: **Web**
- Authentication Method: **PKCE** (recommended) or **Code** (if using client secret)
- Redirect URI: `http://localhost:4001/auth/callback`
- Post-Logout URI: `http://localhost:4001`

Copy the **Client ID** (and **Client Secret** if using Code flow).

### 3. Native Application (CLI — Device Flow)

In the same project, **New** > **Application**:

- Name: `Arbor CLI`
- Type: **Native**
- Authentication Method: **None** (device flow is a public client)
- Redirect URI: not needed for device flow

Copy the **Client ID**.

> Note: Both apps can share the same Client ID if you use a single Native app
> (native apps support both device flow and auth code + PKCE).

## Configure Arbor

Add to your `.env` in the Arbor root:

```bash
OIDC_ISSUER=http://localhost:8080
OIDC_CLIENT_ID=<your-client-id>
OIDC_CLIENT_SECRET=<your-client-secret>  # omit for PKCE / native apps
```

Restart Arbor. The dashboard will redirect to Zitadel for authentication.

## Architecture

| Service | Role | Port |
|---------|------|------|
| `proxy` (Traefik) | Routes `/api`, `/ui/v2/login`, console | 8080 |
| `zitadel-api` | Go API + console + OIDC endpoints | internal |
| `zitadel-login` | Next.js login UI | internal |
| `postgres` | Zitadel database (separate from Arbor) | internal |

## Stopping

```bash
docker compose down        # stop, keep data
docker compose down -v     # stop and delete all data
```

## Production Notes

Before exposing to a network:

1. Change `ZITADEL_MASTERKEY` in `.env` (must be exactly 32 characters)
2. Change all PostgreSQL passwords
3. Set `ZITADEL_DOMAIN` to your actual domain
4. Add TLS via the official [TLS overlay](https://zitadel.com/docs/self-hosting/deploy/compose)
