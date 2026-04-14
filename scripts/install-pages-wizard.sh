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
GENERATED_VALUES=""

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

prompt_required_text() {
    local label="$1"
    local value=""
    while [ -z "${value}" ]; do
        read -r -p "${label}: " value || true
        if [ -z "${value}" ]; then
            echo "This value cannot be empty."
        fi
    done
    printf '%s' "${value}"
}

prompt_mode() {
    local label="$1"
    local default_choice="$2"
    local allow_generate="$3"
    local allow_skip="$4"
    local answer=""
    local options="[m]anual"

    if [ "${allow_generate}" = "1" ]; then
        options="${options}/[g]enerate"
    fi
    if [ "${allow_skip}" = "1" ]; then
        options="${options}/[s]kip"
    fi

    while true; do
        read -r -p "${label} ${options} [${default_choice}]: " answer || true
        answer="$(printf '%s' "${answer:-${default_choice}}" | tr '[:upper:]' '[:lower:]')"
        case "${answer}" in
            m|manual)
                printf 'manual'
                return
                ;;
            g|generate)
                if [ "${allow_generate}" = "1" ]; then
                    printf 'generate'
                    return
                fi
                ;;
            s|skip)
                if [ "${allow_skip}" = "1" ]; then
                    printf 'skip'
                    return
                fi
                ;;
        esac
        echo "Please choose one of the listed options."
    done
}

prompt_yes_no() {
    local label="$1"
    local default_answer="${2:-n}"
    local answer=""

    while true; do
        read -r -p "${label} [y/n] [${default_answer}]: " answer || true
        answer="$(printf '%s' "${answer:-${default_answer}}" | tr '[:upper:]' '[:lower:]')"
        case "${answer}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
        esac
        echo "Please answer y or n."
    done
}

write_toml_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

record_generated_value() {
    local label="$1"
    local value="$2"
    GENERATED_VALUES="${GENERATED_VALUES}${label}: ${value}"$'\n'
}

generate_random_alnum() {
    local length="$1"
    local output=""
    while [ "${#output}" -lt "${length}" ]; do
        if command_exists openssl; then
            output="${output}$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
        else
            output="${output}$(uuidgen | tr -d '-' | tr '[:lower:]' '[:upper:]')"
        fi
    done
    printf '%s' "${output:0:${length}}"
}

generate_random_slug() {
    printf '%s' "$(generate_random_alnum "$1" | tr '[:upper:]' '[:lower:]')"
}

generate_uuid_v4() {
    local hex
    local variant
    if command_exists openssl; then
        hex="$(openssl rand -hex 16)"
    else
        hex="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
    fi
    hex="${hex:0:32}"
    case $(( RANDOM % 4 )) in
        0) variant="8" ;;
        1) variant="9" ;;
        2) variant="a" ;;
        *) variant="b" ;;
    esac
    hex="${hex:0:12}4${hex:13:3}${variant}${hex:17:15}"
    printf '%s-%s-%s-%s-%s' \
        "${hex:0:8}" \
        "${hex:8:4}" \
        "${hex:12:4}" \
        "${hex:16:4}" \
        "${hex:20:12}"
}

is_uuid_v4() {
    printf '%s' "$1" | grep -Eqi '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

prompt_uuid_v4() {
    local label="$1"
    local value=""
    while true; do
        read -r -p "${label}: " value || true
        value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
        if is_uuid_v4 "${value}"; then
            printf '%s' "${value}"
            return
        fi
        echo "Please enter a valid UUID v4."
    done
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
if [ -z "${PROJECT_NAME}" ]; then
    PROJECT_NAME_MODE="$(prompt_mode "Cloudflare Pages project name" "m" "1" "0")"
    if [ "${PROJECT_NAME_MODE}" = "generate" ]; then
        PROJECT_NAME="${DEFAULT_PROJECT_NAME}-$(generate_random_slug 6)"
        echo "Generated Pages project name: ${PROJECT_NAME}"
        record_generated_value "Pages project name" "${PROJECT_NAME}"
    else
        PROJECT_NAME="$(prompt_with_default "Cloudflare Pages project name" "${DEFAULT_PROJECT_NAME}")"
    fi
fi

PRODUCTION_BRANCH="${CF_PAGES_BRANCH:-}"
PRODUCTION_BRANCH="${PRODUCTION_BRANCH:-$(prompt_with_default "Production branch" "${DEFAULT_BRANCH}")}"

KV_NAMESPACE_TITLE="${CF_KV_NAMESPACE:-}"
if [ -z "${KV_NAMESPACE_TITLE}" ]; then
    KV_NAMESPACE_TITLE="$(prompt_with_default "KV namespace title" "${PROJECT_NAME}-kv")"
fi

COMPATIBILITY_DATE="${CF_COMPATIBILITY_DATE:-}"
COMPATIBILITY_DATE="${COMPATIBILITY_DATE:-$(prompt_with_default "Compatibility date" "${DEFAULT_COMPATIBILITY_DATE}")}"

ADMIN_SECRET="${EDGETUNNEL_ADMIN:-${ADMIN:-}}"
if [ -z "${ADMIN_SECRET}" ]; then
    ADMIN_MODE="$(prompt_mode "Admin password for /admin" "g" "1" "0")"
    if [ "${ADMIN_MODE}" = "generate" ]; then
        ADMIN_SECRET="$(generate_random_alnum 24)"
        echo "Generated admin password."
        record_generated_value "Admin password" "${ADMIN_SECRET}"
    else
        ADMIN_SECRET="$(prompt_secret "Admin password for /admin")"
    fi
fi

KEY_VALUE="${KEY:-}"
if [ -z "${KEY_VALUE}" ]; then
    KEY_MODE="$(prompt_mode "Optional KEY secret" "s" "1" "1")"
    case "${KEY_MODE}" in
        manual)
            KEY_VALUE="$(prompt_secret "KEY secret")"
            ;;
        generate)
            KEY_VALUE="$(generate_random_alnum 20)"
            echo "Generated KEY secret."
            record_generated_value "KEY" "${KEY_VALUE}"
            ;;
        skip)
            KEY_VALUE=""
            ;;
    esac
fi

UUID_VALUE="${UUID:-}"
if [ -n "${UUID_VALUE}" ] && ! is_uuid_v4 "${UUID_VALUE}"; then
    echo "Provided UUID must be a valid UUID v4."
    exit 1
fi
if [ -z "${UUID_VALUE}" ]; then
    UUID_MODE="$(prompt_mode "Optional fixed UUID" "s" "1" "1")"
    case "${UUID_MODE}" in
        manual)
            UUID_VALUE="$(prompt_uuid_v4 "UUID v4")"
            ;;
        generate)
            UUID_VALUE="$(generate_uuid_v4)"
            echo "Generated UUID v4."
            record_generated_value "UUID" "${UUID_VALUE}"
            ;;
        skip)
            UUID_VALUE=""
            ;;
    esac
fi

PROXYIP_VALUE="${PROXYIP:-}"
if [ -z "${PROXYIP_VALUE}" ]; then
    PROXYIP_MODE="$(prompt_mode "Optional PROXYIP value" "s" "0" "1")"
    if [ "${PROXYIP_MODE}" = "manual" ]; then
        PROXYIP_VALUE="$(prompt_required_text "PROXYIP value")"
    fi
fi

URL_VALUE="${URL:-}"
if [ -z "${URL_VALUE}" ]; then
    URL_MODE="$(prompt_mode "Optional URL disguise value" "s" "0" "1")"
    if [ "${URL_MODE}" = "manual" ]; then
        URL_VALUE="$(prompt_required_text "URL value")"
    fi
fi

GO2SOCKS5_VALUE="${GO2SOCKS5:-}"
if [ -z "${GO2SOCKS5_VALUE}" ]; then
    GO2SOCKS5_MODE="$(prompt_mode "Optional GO2SOCKS5 value" "s" "0" "1")"
    if [ "${GO2SOCKS5_MODE}" = "manual" ]; then
        GO2SOCKS5_VALUE="$(prompt_required_text "GO2SOCKS5 value")"
    fi
fi

HOST_VALUE="${EDGETUNNEL_HOST:-}"
if [ -z "${HOST_VALUE}" ]; then
    HOST_MODE="$(prompt_mode "Optional HOST value" "s" "0" "1")"
    if [ "${HOST_MODE}" = "manual" ]; then
        HOST_VALUE="$(prompt_required_text "HOST value")"
    fi
fi

PATH_VALUE="${EDGETUNNEL_PATH:-}"
if [ -z "${PATH_VALUE}" ]; then
    PATH_MODE="$(prompt_mode "Optional PATH value" "s" "0" "1")"
    if [ "${PATH_MODE}" = "manual" ]; then
        PATH_VALUE="$(prompt_required_text "PATH value")"
    fi
fi

DEBUG_VALUE="${DEBUG:-}"
if [ -z "${DEBUG_VALUE}" ] && prompt_yes_no "Enable DEBUG logging?" "n"; then
    DEBUG_VALUE="true"
fi

OFF_LOG_VALUE="${OFF_LOG:-}"
if [ -z "${OFF_LOG_VALUE}" ] && prompt_yes_no "Disable request logging (OFF_LOG)?" "n"; then
    OFF_LOG_VALUE="true"
fi

BEST_SUB_VALUE="${BEST_SUB:-}"
if [ -z "${BEST_SUB_VALUE}" ] && prompt_yes_no "Enable BEST_SUB mode?" "n"; then
    BEST_SUB_VALUE="true"
fi

echo
echo "Deployment summary:"
echo "Pages project: ${PROJECT_NAME}"
echo "Production branch: ${PRODUCTION_BRANCH}"
echo "KV namespace: ${KV_NAMESPACE_TITLE}"
echo "Compatibility date: ${COMPATIBILITY_DATE}"
if [ -n "${GENERATED_VALUES}" ]; then
    echo
    echo "Generated values:"
    printf '%s' "${GENERATED_VALUES}"
fi

if ! prompt_yes_no "Continue with Cloudflare login and deployment?" "y"; then
    echo "Cancelled."
    exit 0
fi

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
put_pages_secret "KEY" "${KEY_VALUE}"
put_pages_secret "UUID" "${UUID_VALUE}"
put_pages_secret "PROXYIP" "${PROXYIP_VALUE}"
put_pages_secret "URL" "${URL_VALUE}"
put_pages_secret "GO2SOCKS5" "${GO2SOCKS5_VALUE}"
put_pages_secret "DEBUG" "${DEBUG_VALUE}"
put_pages_secret "OFF_LOG" "${OFF_LOG_VALUE}"
put_pages_secret "BEST_SUB" "${BEST_SUB_VALUE}"
put_pages_secret "HOST" "${HOST_VALUE}"
put_pages_secret "PATH" "${PATH_VALUE}"

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
if [ -n "${GENERATED_VALUES}" ]; then
    echo
    echo "Generated values used in this deployment:"
    printf '%s' "${GENERATED_VALUES}"
fi
