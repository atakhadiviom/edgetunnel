#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKER_ENTRY="${REPO_ROOT}/_worker.js"

if [ ! -f "${WORKER_ENTRY}" ]; then
    echo "Could not find ${WORKER_ENTRY}."
    exit 1
fi

if [ -f "${REPO_ROOT}/wrangler.toml" ]; then
    DEFAULT_COMPATIBILITY_DATE="$(awk -F'"' '/^compatibility_date[[:space:]]*=/{print $2; exit}' "${REPO_ROOT}/wrangler.toml")"
else
    DEFAULT_COMPATIBILITY_DATE=""
fi
DEFAULT_COMPATIBILITY_DATE="${DEFAULT_COMPATIBILITY_DATE:-$(date -u +%F)}"

DEFAULT_PROJECT_NAME="$(basename "${REPO_ROOT}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
DEFAULT_PROJECT_NAME="${DEFAULT_PROJECT_NAME:-edgetunnel}"
DEFAULT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
DEFAULT_KV_NAMESPACE="${DEFAULT_PROJECT_NAME}-kv"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edgetunnel-pages.XXXXXX")"
WORK_DIR="${TMP_DIR}/work"
ASSETS_DIR="${WORK_DIR}/site"
CONFIG_PATH="${WORK_DIR}/wrangler.toml"

cleanup() {
    if [ "${KEEP_TMP_DIR:-0}" = "1" ]; then
        echo "Temporary workspace kept at ${TMP_DIR}"
        return
    fi
    rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

mkdir -p "${WORK_DIR}" "${ASSETS_DIR}"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

if command_exists wrangler; then
    WRANGLER_CMD=(wrangler)
elif command_exists npx; then
    WRANGLER_CMD=(npx --yes wrangler@latest)
elif command_exists pnpm; then
    WRANGLER_CMD=(pnpm dlx wrangler@latest)
elif command_exists bunx; then
    WRANGLER_CMD=(bunx wrangler@latest)
else
    echo "Wrangler is required."
    echo "Install Node.js so the script can run 'npx wrangler', or install Wrangler globally and rerun."
    exit 1
fi

run_wrangler() {
    (
        cd "${WORK_DIR}"
        "${WRANGLER_CMD[@]}" "$@"
    )
}

prompt_with_default() {
    local label="$1"
    local default_value="$2"
    local value
    read -r -p "${label} [${default_value}]: " value || true
    if [ -z "${value}" ]; then
        value="${default_value}"
    fi
    printf '%s' "${value}"
}

prompt_secret() {
    local label="$1"
    local value=""
    while [ -z "${value}" ]; do
        read -r -s -p "${label}: " value || true
        printf '\n'
        if [ -z "${value}" ]; then
            echo "This value cannot be empty."
        fi
    done
    printf '%s' "${value}"
}

write_toml_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

extract_kv_namespace_id() {
    local title="$1"
    local json="$2"
    printf '%s\n' "${json}" | awk -v title="${title}" '
        BEGIN { RS="}"; FS="\n" }
        index($0, "\"title\": \"" title "\"") {
            if (match($0, /"id": "([^"]+)"/, hit)) {
                print hit[1]
                exit
            }
        }
    '
}

put_pages_secret() {
    local key="$1"
    local value="$2"
    if [ -z "${value}" ]; then
        return
    fi
    printf '%s' "${value}" | run_wrangler pages secret put "${key}" --project-name "${PROJECT_NAME}" >/dev/null
    echo "Saved Pages secret ${key}"
}

echo "edgetunnel Cloudflare Pages wizard"
echo
echo "Optional runtime variables can be provided before running the script:"
echo "KEY UUID PROXYIP URL GO2SOCKS5 DEBUG OFF_LOG BEST_SUB EDGETUNNEL_HOST EDGETUNNEL_PATH"
echo "EDGETUNNEL_HOST maps to the worker HOST variable."
echo "EDGETUNNEL_PATH maps to the worker PATH variable."
echo

PROJECT_NAME="${CF_PAGES_PROJECT:-}"
PROJECT_NAME="${PROJECT_NAME:-$(prompt_with_default "Cloudflare Pages project name" "${DEFAULT_PROJECT_NAME}")}"

PRODUCTION_BRANCH="${CF_PAGES_BRANCH:-}"
PRODUCTION_BRANCH="${PRODUCTION_BRANCH:-$(prompt_with_default "Production branch" "${DEFAULT_BRANCH}")}"

KV_NAMESPACE_TITLE="${CF_KV_NAMESPACE:-}"
KV_NAMESPACE_TITLE="${KV_NAMESPACE_TITLE:-$(prompt_with_default "KV namespace title" "${DEFAULT_KV_NAMESPACE}")}"

COMPATIBILITY_DATE="${CF_COMPATIBILITY_DATE:-}"
COMPATIBILITY_DATE="${COMPATIBILITY_DATE:-$(prompt_with_default "Compatibility date" "${DEFAULT_COMPATIBILITY_DATE}")}"

ADMIN_SECRET="${EDGETUNNEL_ADMIN:-${ADMIN:-}}"
ADMIN_SECRET="${ADMIN_SECRET:-$(prompt_secret "Admin password for /admin")}"

echo
echo "Opening the Cloudflare browser login flow..."
run_wrangler login

echo
echo "Authenticated account:"
run_wrangler whoami

echo
echo "Creating or reusing Pages project ${PROJECT_NAME}..."
PROJECT_LOG="${TMP_DIR}/pages-project.log"
if run_wrangler pages project create "${PROJECT_NAME}" --production-branch "${PRODUCTION_BRANCH}" --compatibility-date "${COMPATIBILITY_DATE}" >"${PROJECT_LOG}" 2>&1; then
    cat "${PROJECT_LOG}"
else
    if grep -qi "already exists" "${PROJECT_LOG}"; then
        echo "Pages project already exists, reusing it."
    else
        cat "${PROJECT_LOG}" >&2
        exit 1
    fi
fi

echo
echo "Creating or reusing KV namespace ${KV_NAMESPACE_TITLE}..."
KV_CREATE_LOG="${TMP_DIR}/kv-create.log"
if run_wrangler kv namespace create "${KV_NAMESPACE_TITLE}" >"${KV_CREATE_LOG}" 2>&1; then
    cat "${KV_CREATE_LOG}"
else
    if grep -qi "already exists" "${KV_CREATE_LOG}"; then
        echo "KV namespace already exists, reusing it."
    else
        cat "${KV_CREATE_LOG}" >&2
        exit 1
    fi
fi

KV_LIST_JSON="$(run_wrangler kv namespace list)"
KV_NAMESPACE_ID="$(extract_kv_namespace_id "${KV_NAMESPACE_TITLE}" "${KV_LIST_JSON}")"
if [ -z "${KV_NAMESPACE_ID}" ]; then
    echo "Unable to find the namespace id for ${KV_NAMESPACE_TITLE}."
    exit 1
fi

echo "Using KV namespace id ${KV_NAMESPACE_ID}"

cp "${WORKER_ENTRY}" "${ASSETS_DIR}/_worker.js"

cat > "${CONFIG_PATH}" <<EOF
name = "$(write_toml_string "${PROJECT_NAME}")"
compatibility_date = "$(write_toml_string "${COMPATIBILITY_DATE}")"
pages_build_output_dir = "site"
keep_vars = true

[[kv_namespaces]]
binding = "KV"
id = "$(write_toml_string "${KV_NAMESPACE_ID}")"
EOF

echo
echo "Uploading Pages secrets..."
put_pages_secret "ADMIN" "${ADMIN_SECRET}"
put_pages_secret "KEY" "${KEY:-}"
put_pages_secret "UUID" "${UUID:-}"
put_pages_secret "PROXYIP" "${PROXYIP:-}"
put_pages_secret "URL" "${URL:-}"
put_pages_secret "GO2SOCKS5" "${GO2SOCKS5:-}"
put_pages_secret "DEBUG" "${DEBUG:-}"
put_pages_secret "OFF_LOG" "${OFF_LOG:-}"
put_pages_secret "BEST_SUB" "${BEST_SUB:-}"
put_pages_secret "HOST" "${EDGETUNNEL_HOST:-}"
put_pages_secret "PATH" "${EDGETUNNEL_PATH:-}"

echo
echo "Deploying to Cloudflare Pages..."
DEPLOY_LOG="${TMP_DIR}/pages-deploy.log"
if run_wrangler pages deploy "${ASSETS_DIR}" --project-name "${PROJECT_NAME}" --branch "${PRODUCTION_BRANCH}" >"${DEPLOY_LOG}" 2>&1; then
    cat "${DEPLOY_LOG}"
else
    cat "${DEPLOY_LOG}" >&2
    exit 1
fi

echo
echo "Deployment complete."
echo "Panel: https://${PROJECT_NAME}.pages.dev/admin"
echo "Login: https://${PROJECT_NAME}.pages.dev/login"
