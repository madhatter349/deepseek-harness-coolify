# DeepSeek Harness on Coolify

Self-hosted, always-on **DeepSeek Harness** (`dsh`) built from the official
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
release and productionized for a Coolify VPS.

```
browser ──HTTPS──▶ Coolify Traefik ──▶ authenticated DeepSeek Harness ──▶ VPS workspace/repos
                     (TLS + Basic Auth)   (browser-session auth)          (OpenAI-compatible API)
```

Everything runs on the VPS. The browser is a thin client; nothing is installed
locally. One container, one persistent volume, no database and no extra
services — the Harness does not need them (sessions are append-only JSONL files
under its home directory).

---

## What this repository is

| File | Purpose |
|---|---|
| `Dockerfile` | Installs the official `@deepseek-ai/dsh` release plus the runtime toolchain (git, ssh, python, build tools) |
| `deploy/entrypoint.sh` | Prepares the volume, seeds the model route once, supervises `dsh web`, captures the first-visit URL |
| `deploy/cordis.deploy.yml` | Deployment overlay: container bind, browser-trust fence, privacy defaults |
| `deploy/profile.seed.patch.yml` | Env-driven OpenAI-compatible provider + default model |
| `deploy/healthcheck.sh` | Container healthcheck (root reachable and authenticated) |
| `docker-compose.yml` | Local/plain-VPS compose deployment |
| `.env.example` | Every runtime variable with examples |
| `scripts/coolify-setup.sh` | Idempotent Coolify app creation (API) |
| `scripts/smoke-test.sh` | Post-deploy verification |

## Design decisions

**Official npm release, not a source build.** The upstream README publishes
`@deepseek-ai/dsh` ("Run from npm") as the supported production path; the same
monorepo build is a development workflow. Installing the published launcher
keeps deploys to ~1 minute and ~600 MB instead of a multi-GB TypeScript build of
14,000 files, while still running the official DeepSeek Harness core with its
full dependency closure. `DSH_VERSION` pins the release.

**No database, no second service.** dsh persists sessions as JSONL files,
settings as YAML/JSON, and credentials under one home directory. A single named
volume mounted at `/data` holds everything. Coolify's existing Traefik provides
TLS; no auth proxy container is added.

**Two independent authentication layers.**
1. **Coolify/Traefik HTTP Basic Auth** at the public edge (the
   `is_http_basic_auth_enabled` application setting) — nothing reaches the
   container without it.
2. **dsh browser-session auth** at the application. The server mints a random
   launch token per process, prints a private `?token=…` URL, and exchanges it
   for an authority-bound signed `HttpOnly` cookie. Every API call and
   WebSocket stream is checked; unauthenticated index requests get `401`.
   `DSH_COOKIE_MAX_AGE_DAYS` controls how long a browser stays signed in
   (default 365 days; the signing secret lives on the volume and survives
   restarts and redeploys).

**The container port is never published.** `dsh web` normally binds loopback
only and the CLI refuses `--host 0.0.0.0`. The deployment overlay sets the
webserver bind to `0.0.0.0` so Traefik can reach it *inside the private Docker
network*; Coolify publishes no host port for this app. The `/api` trust fence
additionally requires the forwarded `Host` header to be in `DSH_TRUSTED_HOSTS`.

**Credentials are environment-only.** The API key is referenced by name
(`apiKeyEnv: DSH_LLM_API_KEY`) and resolved from the process environment; no
secret is stored in a config file baked into the image. The base URL, model
list and capacities are all read from the environment at boot.

---

## Local verification (optional, no local install)

```bash
cp .env.example .env         # fill in DSH_LLM_* and DSH_TRUSTED_HOSTS
docker compose up -d --build
docker compose logs -f dsh   # watch for the "first-visit URL ready" line
./scripts/smoke-test.sh      # BASE_URL defaults to http://127.0.0.1:13080
TOKEN=<token> BASE_URL=http://127.0.0.1:13080 ./scripts/smoke-test.sh
```

The compose port mapping binds `127.0.0.1:<DSH_HOST_PORT>` only. Delete the
`ports:` block when running under Coolify.

---

## Deploy to Coolify

### Option A — scripted (recommended)

```bash
export COOLIFY_URL="https://coolify.example.com"
export COOLIFY_API_TOKEN="..."           # Coolify → Keys & Tokens
export GITHUB_REPO="https://github.com/<owner>/deepseek-harness-coolify.git"
export DSH_DOMAIN="dsh.example.com"
export BASIC_AUTH_USER="dsh"
export BASIC_AUTH_PASSWORD="$(openssl rand -base64 24)"
export DSH_LLM_BASE_URL="https://inference.example.com/v1"
export DSH_LLM_API_KEY="<gateway token>"
export DSH_LLM_MODELS="deepseek-v4.1-flash"

./scripts/coolify-setup.sh
```

The script creates the project (if missing), the Dockerfile application with
the domain and Basic Auth, upserts every environment variable, adds the
`/data` persistent volume, and queues the first deployment.

### Option B — dashboard

1. **Project** → New Project → name it e.g. *DeepSeek Harness*.
2. **+ New Resource → Public Repository** → paste the repository URL,
   branch `main`, build pack **Dockerfile**, Dockerfile location `/Dockerfile`.
3. **Configuration → General**: Ports Exposes `3080`; Domains add
   `https://dsh.example.com`; enable *Force HTTPS*.
4. **Configuration → Advanced → HTTP Basic Authentication**: enable, set the
   username and a strong password.
5. **Environment Variables**: paste the pairs from `.env.example` with real
   values (the `DSH_LLM_*` block is the important part).
6. **Persistent Storage**: add a volume named `deepseek-harness-data` mounted at
   `/data`.
7. **Deploy**.

### DNS

`dsh.example.com` must resolve to the VPS (`A` record or wildcard) before the
first deploy so Traefik can issue the Let's Encrypt certificate.

---

## First login

1. Open `https://dsh.example.com/` — the browser asks for the **Basic Auth**
   credentials from step 4/script.
2. Get the private first-visit URL:

   ```bash
   docker exec <container> cat /data/dsh-home/last-login-url.txt
   # → https://dsh.example.com/?token=…
   ```

   It is also printed in the container logs and is rewritten on every boot
   (`dsh web: …?token=…`). The token is a bearer credential: treat the file as a
   secret.
3. Open that URL once. dsh sets the signed session cookie and redirects to the
   clean UI. Subsequent visits (including after restarts) need only Basic Auth
   until the cookie expires.

The Models page shows the env-configured **DSH Gateway** provider; new sessions
default to its first model. No credentials are ever typed into the UI.

---

## Environment reference

| Variable | Default | Meaning |
|---|---|---|
| `DSH_HOME` | `/data/dsh-home` | Harness home: config, credentials, sessions, logs |
| `DSH_WORKSPACE_DIR` | `/data/workspace` | Working directory for sessions and repositories |
| `PORT` | `3080` | Container HTTP port (Traefik target) |
| `DSH_PUBLIC_URL` | – | Public origin used in the first-visit URL file |
| `DSH_TRUSTED_HOSTS` | – | Comma-separated `Host` authorities accepted by the `/api` fence |
| `DSH_COOKIE_MAX_AGE_DAYS` | `365` | Browser-session cookie lifetime |
| `DSH_LLM_BASE_URL` | `https://api.deepseek.com/v1` | OpenAI-compatible API root |
| `DSH_LLM_API_KEY` | – | Bearer token (credential reference `DSH_LLM_API_KEY`) |
| `DSH_AMD_API_KEY` | – | AMD Radeon developer API token |
| `DSH_OPENCODE_API_KEY` | – | OpenCode Zen token (`x-opencode-session` header is in the patch) |
| `DSH_CLINE_API_KEY` | – | ClinePass token (route commented out until the account balance is positive) |
| `DSH_LLM_CONTEXT_WINDOW` | `131072` | Fallback context capacity for models without one |
| `DSH_LLM_MAX_OUTPUT_TOKENS` | `8192` | Fallback output cap for models without one |
| `DSH_TELEMETRY_DISABLED` | `1` | Disables OTel delivery |
| `DSH_SESSION_LOG_UPLOAD` | `0` | DeepSeek official session-log upload opt-in |

The model catalogue lives in the profile patch
`$DSH_HOME/profiles/web/cordis.patch.yml` on the volume (seeded once from
`deploy/profile.seed.patch.yml`); edit that file to add or remove models, then
restart the container. The deployment overlay enables HMR polling, which
applies default-model edits live; provider-route edits need the restart.

## Model gateway notes

- The seeded catalogue consolidates every MiMo V2.6 Flash / DeepSeek V4.1
  source from the pi agent's provider list:

  | Provider | Models |
  |---|---|
  | CI Gateway (queue) | `deepseek-v4.1-flash`, `mimo-v2.6-flash` |
  | AMD Radeon | `DeepSeek-V4.1-Flash`, `MiMo-V2.6-Flash` |
  | OpenCode Go | `deepseek-v4.1-flash` |
  | ClinePass | `deepseek/deepseek-v4.1-flash`, `xiaomi/mimo-v2.6-flash` (commented out: HTTP 402 balance) |

  The misnamed, unconfigured official DeepSeek entries (`DeepSeek-V41-Flash`,
  `DeepSeek-V4-Pro`) are hidden by `llm-deepseek: disabled`; remove that row
  (or set `DEEPSEEK_API_KEY`) to bring them back. Edit
  `$DSH_HOME/profiles/web/cordis.patch.yml` to add or remove models, then
  restart the container (`docker restart <container>`) — on 0.2.0-rc.2 the
  `llm-pi-ai` provider routes do not re-register on a hot patch edit.
- The route uses **OpenAI Chat Completions** (`openai-completions`), which
  covers the DeepSeek official API, a CheapestInference/queue gateway, LiteLLM,
  vLLM, OpenRouter and similar relays.
- The DeepSeek official API is `https://api.deepseek.com/v1` with models
  `deepseek-chat` / `deepseek-reasoner`; the native `dsh-llm-deepseek` adapter
  is *not* configured here because it speaks Anthropic Messages, not OpenAI.
- The gateway must answer `POST {baseURL}/chat/completions` and, for the
  "Fetch available models" button, `GET {baseURL}/models`.
- Image input: a hand-declared model is text-only by default. In the Models
  page enable **Image** on the model (and make sure the gateway serves vision)
  to use screenshots or images with the agent.
- Reasoning effort: the Effort menu appears only for models that declare
  levels. A DeepSeek model that always thinks can be corrected with
  `compat.thinkingFormat: deepseek` in the same profile patch.

### Remote browsers cannot open Host settings

dsh enables the editable Host settings document only for loopback page
origins (`ctx.remote.$host.isLoopback`, i.e. `localhost`, `127.0.0.0/8`, or
`[::1]`). Browsing through the public Coolify domain therefore shows
**"Loading the provider directory failed: settings are unavailable in this
browser"** on Settings → Models, and plugin configuration forms stay
unavailable. This is upstream behavior, not a deployment fault:
`packages/client/ui-settings/README.md` states "Non-loopback pages get no
durable settings — form writes are inert".

The env-configured provider still works, and new sessions still default to its
first model. To add or change providers while remote, edit
`$DSH_HOME/profiles/web/cordis.patch.yml` directly — for example from the Web
UI's terminal sidebar — and restart the container after the edit:

```yaml
- id: llm-pi-ai
  config:
    providers:
      dsh-gateway:
        apiKeyEnv: DSH_LLM_API_KEY
        api: openai-completions
        baseURL: !!js process.env.DSH_LLM_BASE_URL
        models:
          - id: deepseek-v4.1-flash
          - id: another-model
```

Only a loopback browser gets the editable Models UI (an SSH tunnel to the
container port presents one).

## Persistence layout

```
/data
├── dsh-home/                 # $DSH_HOME (volume)
│   ├── .credentials.yaml     # cookie signing secret, saved credentials
│   ├── profiles/web/         # web profile: manifest + user patches
│   ├── sessions/             # append-only JSONL session logs (resumable)
│   ├── storages/             # JSON storage backend
│   ├── logs/                 # per-boot logs
│   ├── .ssh/                 # agent SSH keys (symlinked from /root/.ssh)
│   ├── gitconfig             # agent git identity (symlinked from /root/.gitconfig)
│   └── last-login-url.txt    # private first-visit URL (mode 600)
└── workspace/                # working directory: repos and files
```

Because `DSH_HOME` is on the volume, sessions are **persistent and resumable**:
the Web UI lists history after redeploys and container restarts. Back up
`/data` (or at least `dsh-home`) with Coolify's volume backup feature or restic;
treat `dsh-home` as secret material.

## Updating

1. Change `ARG DSH_VERSION` in the `Dockerfile` to a newer published release
   (`npm view @deepseek-ai/dsh version`).
2. Commit and push.
3. Coolify → app → **Deploy** (or `POST /api/v1/deploy?uuid=<uuid>`).

Harness is a developer preview with compatibility-breaking changes; test a new
release against a copy of the volume before rolling it out.

## Troubleshooting

| Symptom | Check |
|---|---|
| `502` from Traefik | Container logs; `dsh web` may have failed to boot (patch error). `docker logs <container>` |
| Redirect loop / `401` after token URL | `DSH_TRUSTED_HOSTS` must contain the exact public authority (no scheme) |
| `403` on `/api` | Wrong `Host` forwarded; fix `DSH_TRUSTED_HOSTS` and redeploy |
| Model requests fail | `curl -H "Authorization: Bearer $DSH_LLM_API_KEY" "$DSH_LLM_BASE_URL/models"` from inside the container; check base URL, key and model id |
| `MISSING_CREDENTIAL` | `DSH_LLM_API_KEY` is unset in the application environment |
| First-visit URL missing | The server may not have reached readiness; inspect `$DSH_HOME/logs/boot-*.log` |
| "Loading the provider directory failed: settings are unavailable in this browser" | Expected upstream behavior for non-loopback origins; edit `$DSH_HOME/profiles/web/cordis.patch.yml` directly (HMR applies it) or use a loopback/SSH-tunnel browser |
| Coolify API returns HTML or 500 while creating the app | Send `Accept: application/json`; Coolify encrypts the Basic Auth password into `varchar(255)`, so keep it ≤16 characters |
| Healthcheck unhealthy | `GET /` must answer; check boot log and port env |
| Plugin install fails in UI | `pnpm` is installed in the image; native builds use the bundled `build-essential` |
