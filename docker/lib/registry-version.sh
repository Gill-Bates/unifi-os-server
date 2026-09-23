#!/usr/bin/env bash
# Shared Docker Hub / OCI registry version-resolution helpers.
#
# Sourced by both docker/build.sh (local/CI build) and the create-manifest
# job in .github/workflows/docker-build.yml (via bash --noprofile --norc
# defaults: shell), so that "what is the currently published :latest
# version" and "is candidate >= baseline" have exactly one implementation.
#
# Contract for callers:
#   - This file only defines functions. It has no side effects on source
#     and does not set -e/-u/-o pipefail itself — the caller's shell mode
#     applies to code run from these functions.
#   - Every function takes its inputs as explicit arguments; none of them
#     read IMAGE_NAME, VERSION, or any other global directly. Callers must
#     resolve the repo path and bearer token themselves and pass them in.
#   - log()/warn() are not used here — callers get plain stdout/stderr and
#     interpret exit codes; this keeps the library usable from both a
#     Bash script with custom logging and a GitHub Actions run: block.
#
# Requires: bash, curl, jq, sort -V (GNU coreutils).

# version_ge CANDIDATE BASELINE
# Returns success if CANDIDATE >= BASELINE under version-aware sort order.
version_ge() {
    local candidate="$1"
    local baseline="$2"

    [[ "$(printf '%s\n%s\n' "$baseline" "$candidate" | sort -V | tail -n 1)" == "$candidate" ]]
}

# docker_hub_repo_path IMAGE_NAME
# Normalizes an image reference to a Docker-Hub-style "namespace/repo" path.
# Prints the normalized path on stdout.
# Returns 1 if IMAGE_NAME does not refer to Docker Hub (a third-party
# registry host or a registry with an explicit port) — callers must not
# query registry-1.docker.io for such images.
docker_hub_repo_path() {
    local image="$1"
    local first_component="${image%%/*}"

    if [[ "$image" == docker.io/* ]]; then
        image="${image#docker.io/}"
    elif [[ "$image" == registry-1.docker.io/* ]]; then
        image="${image#registry-1.docker.io/}"
    elif [[ "$first_component" == *.* || "$first_component" == *:* || "$first_component" == "localhost" ]]; then
        return 1
    fi

    if [[ "$image" != */* ]]; then
        image="library/${image}"
    fi

    printf '%s\n' "$image"
}

# fetch_docker_hub_token REPO
# Fetches an anonymous, read-only (pull-scoped) bearer token for REPO
# (as returned by docker_hub_repo_path) from Docker Hub's public auth
# endpoint. Prints the token on stdout.
fetch_docker_hub_token() {
    local repo="$1"
    local token

    token="$(
        curl -fsSL \
            --connect-timeout 10 \
            --max-time 20 \
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
            | jq -r '.token // empty'
    )" || return 1

    [[ -n "$token" ]] || return 1
    printf '%s\n' "$token"
}

# _registry_log MESSAGE
# Timestamped stderr diagnostic. Callers have their own loggers (build.sh's
# warn(), the workflow's plain echo), so this stays minimal — but it keeps
# the ISO timestamp the project requires of build/CI logs.
_registry_log() {
    printf '%s [registry] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# fetch_registry_json URL TOKEN [ACCEPT_HEADER]
# GETs URL against the OCI/Docker registry API with the given bearer TOKEN.
# Prints the response body on stdout on HTTP 200.
# Returns 2 on HTTP 404 (caller must treat "not found" as a distinct case,
# e.g. "no :latest tag published yet"), 1 on any other error.
fetch_registry_json() {
    local url="$1"
    local token="$2"
    local accept_header="${3:-application/json}"
    local response status body

    response="$(
        curl -sS -L -w '\n%{http_code}' \
            --connect-timeout 10 \
            --max-time 20 \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: ${accept_header}" \
            "$url"
    )" || return 1

    status="$(tail -n 1 <<< "$response")"
    body="$(sed '$d' <<< "$response")"

    case "$status" in
        200)
            printf '%s\n' "$body"
            ;;
        404)
            return 2
            ;;
        *)
            _registry_log "Registry request failed with HTTP ${status}: ${url}"
            return 1
            ;;
    esac
}

# fetch_current_latest_version REPO TOKEN
# Resolves the semantic version recorded in the
# org.opencontainers.image.version label of the ":latest" tag's image
# config for REPO, using bearer TOKEN (from fetch_docker_hub_token).
# Prints the version on stdout.
#
# Return codes:
#   0  version resolved, printed on stdout
#   1  transient/unexpected error (network, malformed manifest, missing
#      version label) — caller should treat this as a hard failure, not
#      as "no latest exists"
#   2  no ":latest" tag exists yet — caller should treat this as
#      "promotion allowed", not as an error
#   3  ":latest" exists but its version label is not a usable semver —
#      caller decides whether that blocks the release or only skips
#      promotion (distinct from 1 so a malformed label does not read as
#      a network/registry failure)
fetch_current_latest_version() {
    local repo="$1"
    local token="$2"
    local manifest child_digest child_manifest config_digest config version
    local accept_header='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

    manifest="$(
        fetch_registry_json \
            "https://registry-1.docker.io/v2/${repo}/manifests/latest" \
            "$token" \
            "$accept_header"
    )" || return $?

    child_digest="$(jq -r 'first(.manifests[]? | select(.platform.architecture == "amd64") | .digest) // empty' <<< "$manifest")"
    if [[ -z "$child_digest" ]]; then
        child_digest="$(jq -r '.manifests[0]?.digest // empty' <<< "$manifest")"
    fi

    if [[ -n "$child_digest" ]]; then
        child_manifest="$(
            fetch_registry_json \
                "https://registry-1.docker.io/v2/${repo}/manifests/${child_digest}" \
                "$token" \
                "$accept_header"
        )" || return 1
    else
        child_manifest="$manifest"
    fi

    config_digest="$(jq -r '.config.digest // empty' <<< "$child_manifest")"
    [[ -n "$config_digest" ]] || return 1

    config="$(
        fetch_registry_json \
            "https://registry-1.docker.io/v2/${repo}/blobs/${config_digest}" \
            "$token"
    )" || return 1

    version="$(jq -r '.config.Labels["org.opencontainers.image.version"] // empty' <<< "$config")"
    [[ -n "$version" ]] || return 1
    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]]; then
        _registry_log "Published latest carries a non-semver version label: ${version}"
        return 3
    fi
    printf '%s\n' "$version"
}
