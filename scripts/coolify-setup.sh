#!/usr/bin/env bash
# Idempotent Coolify app setup for DeepSeek Harness.
#
# Required environment (never commit these):
#   COOLIFY_URL            e.g. https://coolify.example.com
#   COOLIFY_API_TOKEN      Coolify API token
#   GITHUB_REPO            e.g. https://github.com/<owner>/deepseek-harness-coolify.git
#   DSH_DOMAIN             e.g. dsh.example.com
#   BASIC_AUTH_USER        Traefik basic-auth username
#   BASIC_AUTH_PASSWORD    Traefik basic-auth password
#   DSH_LLM_BASE_URL       OpenAI-compatible API root
#   DSH_LLM_API_KEY        bearer token for that endpoint
#   DSH_LLM_MODELS         comma-separated model ids
#
# Optional:
#   COOLIFY_PROJECT       project name (default: DeepSeek Harness)
#   APP_NAME              application name (default: deepseek-harness)
#   SERVER_UUID           Coolify server uuid (auto-detected when only one)
#   DSH_COOKIE_MAX_AGE_DAYS DSH_LLM_CONTEXT_WINDOW DSH_LLM_MAX_OUTPUT_TOKENS
set -euo pipefail

: "${COOLIFY_URL:?}" "${COOLIFY_API_TOKEN:?}" "${GITHUB_REPO:?}" "${DSH_DOMAIN:?}"
: "${BASIC_AUTH_USER:?}" "${BASIC_AUTH_PASSWORD:?}"
: "${DSH_LLM_BASE_URL:?}" "${DSH_LLM_API_KEY:?}" "${DSH_LLM_MODELS:?}"

# Coolify encrypts the Basic Auth password into a varchar(255) column; values
# longer than ~16 characters overflow the insert and the API returns a 500.
if [ "${#BASIC_AUTH_PASSWORD}" -gt 16 ]; then
  echo "BASIC_AUTH_PASSWORD must be 16 characters or fewer (Coolify stores it encrypted in varchar(255))." >&2
  exit 1
fi

COOLIFY_URL="${COOLIFY_URL%/}"
project_name="${COOLIFY_PROJECT:-DeepSeek Harness}"
app_name="${APP_NAME:-deepseek-harness}"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$COOLIFY_URL/api/v1$path" \
      -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS -X "$method" "$COOLIFY_URL/api/v1$path" \
      -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
      -H 'Accept: application/json'
  fi
}

# ── server ------------------------------------------------------------------
server_uuid="${SERVER_UUID:-$(api GET /servers | jq -r '.[0].uuid')}"
[ -n "$server_uuid" ] && [ "$server_uuid" != "null" ] || { echo "no Coolify server found" >&2; exit 1; }

# ── project + production environment ----------------------------------------
project_uuid="$(api GET /projects | jq -r --arg n "$project_name" '.[] | select(.name==$n) | .uuid' | head -n1)"
if [ -z "$project_uuid" ]; then
  echo "creating project '$project_name'"
  project_uuid="$(api POST /projects "$(jq -nc --arg n "$project_name" '{name:$n}')" | jq -r '.uuid')"
fi
environment_uuid="$(api GET "/projects/$project_uuid" | jq -r '.environments[] | select(.name=="production") | .uuid' | head -n1)"
[ -n "$environment_uuid" ] || { echo "no production environment" >&2; exit 1; }

# ── application --------------------------------------------------------------
app_uuid="$(api GET /applications | jq -r --arg n "$app_name" '.[] | select(.name==$n) | .uuid' | head -n1)"
if [ -z "$app_uuid" ]; then
  echo "creating application '$app_name'"
  payload="$(jq -nc \
    --arg name "$app_name" --arg project "$project_uuid" --arg env "$environment_uuid" \
    --arg server "$server_uuid" --arg repo "$GITHUB_REPO" --arg domain "https://$DSH_DOMAIN" \
    --arg user "$BASIC_AUTH_USER" --arg pass "$BASIC_AUTH_PASSWORD" \
    '{name:$name, project_uuid:$project, environment_uuid:$env, server_uuid:$server,
      git_repository:$repo, git_branch:"main", build_pack:"dockerfile",
      dockerfile_location:"/Dockerfile", ports_exposes:"3080",
      domains:$domain, autogenerate_domain:false,
      is_http_basic_auth_enabled:true, http_basic_auth_username:$user,
      http_basic_auth_password:$pass, is_auto_deploy_enabled:false,
      is_force_https_enabled:true, instant_deploy:false}')"
  app_uuid="$(api POST /applications/public "$payload" | jq -r '.uuid')"
fi
[ -n "$app_uuid" ] && [ "$app_uuid" != "null" ] || { echo "application creation failed" >&2; exit 1; }

# ── environment --------------------------------------------------------------
envs="$(jq -nc \
  --arg base "$DSH_LLM_BASE_URL" --arg key "$DSH_LLM_API_KEY" --arg models "$DSH_LLM_MODELS" \
  --arg domain "$DSH_DOMAIN" \
  --arg cookie "${DSH_COOKIE_MAX_AGE_DAYS:-365}" \
  --arg ctx "${DSH_LLM_CONTEXT_WINDOW:-131072}" \
  --arg out "${DSH_LLM_MAX_OUTPUT_TOKENS:-8192}" \
  '{data:[
     {key:"DSH_HOME",value:"/data/dsh-home"},
     {key:"DSH_WORKSPACE_DIR",value:"/data/workspace"},
     {key:"PORT",value:"3080"},
     {key:"DSH_PUBLIC_URL",value:("https://" + $domain)},
     {key:"DSH_TRUSTED_HOSTS",value:$domain},
     {key:"DSH_COOKIE_MAX_AGE_DAYS",value:$cookie},
     {key:"DSH_LLM_BASE_URL",value:$base},
     {key:"DSH_LLM_API_KEY",value:$key},
     {key:"DSH_LLM_MODELS",value:$models},
     {key:"DSH_LLM_CONTEXT_WINDOW",value:$ctx},
     {key:"DSH_LLM_MAX_OUTPUT_TOKENS",value:$out},
     {key:"DSH_TELEMETRY_DISABLED",value:"1"},
     {key:"DSH_SESSION_LOG_UPLOAD",value:"0"}
   ]}')"
api PATCH "/applications/$app_uuid/envs/bulk" "$envs" >/dev/null
echo "environment set"

# ── persistent volume --------------------------------------------------------
if ! api GET "/applications/$app_uuid/storages" | jq -e '.persistent_storages | length > 0' >/dev/null; then
  api POST "/applications/$app_uuid/storages" \
    "$(jq -nc '{type:"persistent",name:"deepseek-harness-data",mount_path:"/data"}')" >/dev/null
  echo "persistent volume created"
fi

# ── deploy -------------------------------------------------------------------
echo "queuing deployment for $app_uuid"
api POST "/deploy?uuid=$app_uuid" >/dev/null
echo "deployment queued — watch Coolify logs, then:"
echo "  https://$DSH_DOMAIN/ (basic auth: $BASIC_AUTH_USER)"
echo "  first-visit URL: docker exec <container> cat /data/dsh-home/last-login-url.txt"
