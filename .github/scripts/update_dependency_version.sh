#!/usr/bin/env bash
#
# update_dependency_version.sh
#
# Updates all dependencies used by this project:
#   1) Java major version       (pom.xml, GitHub workflows, devcontainer Dockerfile)
#   2) Maven version (X.Y.Z)     (pom.xml, GitHub workflows, devcontainer Dockerfile)
#   3) GitHub Actions versions   (all workflows under .github/workflows)
#   4) Git submodules            (every submodule defined in .gitmodules)
#   5) pom.xml dependencies      (3PP libraries, plugin versions, etc. via Maven)
#
# Java and Maven are only bumped when a newer version is available for *every*
# place they are referenced, so the versions always stay in sync.
#
# Requirements: bash, curl, jq, git, mvn (and optionally the `gh` CLI for the
# GitHub Actions updates - falls back to the public GitHub API otherwise).

set -euo pipefail

# Always operate from the repository root, regardless of where this script lives
# or is invoked from.
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${REPO_ROOT}" ]; then
    echo "[WARN] Not inside a git repository; falling back to the current directory." >&2
    REPO_ROOT="$(pwd)"
fi
cd "${REPO_ROOT}"

readonly POM_FILE="pom.xml"
readonly DOCKERFILE=".devcontainer/Dockerfile"
readonly WORKFLOW_DIR=".github/workflows"
readonly GITMODULES_FILE=".gitmodules"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()     { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; }
section() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

# Print the highest version from stdin (one version per line), using `sort -V`.
highest_version() { sort -V | tail -n 1; }

# Return 0 (true) if $1 is strictly greater than $2 as a version string.
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | highest_version)" = "$1" ]
}

# Replace all occurrences of a literal string in a file (only writes if changed).
replace_in_file() {
    local file="$1" search="$2" replace="$3"
    [ -f "${file}" ] || return 0
    if grep -qF "${search}" "${file}"; then
        # Use a sed delimiter unlikely to appear in versions/paths.
        local s r
        s="$(printf '%s' "${search}" | sed -e 's/[\/&|]/\\&/g')"
        r="$(printf '%s' "${replace}" | sed -e 's/[\/&|]/\\&/g')"
        sed -i "s|${s}|${r}|g" "${file}"
        log "  updated ${file}: '${search}' -> '${replace}'"
    fi
}

# ---------------------------------------------------------------------------
# 1) Java major version
# ---------------------------------------------------------------------------
update_java_version() {
    section "Java version"

    # Collect every Java version currently referenced.
    local -a current=()
    local v
    v="$(grep -oP '(?<=<java-release>)\d+(?=</java-release>)' "${POM_FILE}" || true)"
    [ -n "${v}" ] && current+=("${v}")

    while IFS= read -r v; do
        [ -n "${v}" ] && current+=("${v}")
    done < <(grep -rhoP '(?<=java-version: ")\d+(?=")' "${WORKFLOW_DIR}" 2>/dev/null || true)

    v="$(grep -oP '(?<=-eclipse-temurin-)\d+' "${DOCKERFILE}" || true)"
    [ -n "${v}" ] && current+=("${v}")

    if [ "${#current[@]}" -eq 0 ]; then
        warn "Could not find any Java version references; skipping."
        return 0
    fi

    local current_max
    current_max="$(printf '%s\n' "${current[@]}" | sort -n | tail -n 1)"
    log "Current Java versions referenced: ${current[*]} (highest: ${current_max})"

    # Latest GA Java feature release, via the Adoptium (Temurin) API.
    local latest
    latest="$(curl -fsSL https://api.adoptium.net/v3/info/available_releases \
        | jq -r '.most_recent_feature_release' 2>/dev/null || true)"

    if ! [[ "${latest}" =~ ^[0-9]+$ ]]; then
        warn "Could not determine latest Java version; skipping."
        return 0
    fi
    log "Latest available Java major version: ${latest}"

    # Only update if it is a genuine update for *every* place (keep in sync).
    if [ "${latest}" -le "${current_max}" ]; then
        log "No Java update available for all locations; leaving unchanged."
        return 0
    fi

    log "Updating Java version to ${latest} in all locations."
    replace_in_file "${POM_FILE}" "<java-release>$(grep -oP '(?<=<java-release>)\d+' "${POM_FILE}")</java-release>" "<java-release>${latest}</java-release>"

    local f cur
    for f in "${WORKFLOW_DIR}"/*.y*ml; do
        [ -f "${f}" ] || continue
        while IFS= read -r cur; do
            replace_in_file "${f}" "java-version: \"${cur}\"" "java-version: \"${latest}\""
        done < <(grep -oP '(?<=java-version: ")\d+(?=")' "${f}" | sort -u)
    done

    cur="$(grep -oP '(?<=-eclipse-temurin-)\d+' "${DOCKERFILE}")"
    replace_in_file "${DOCKERFILE}" "-eclipse-temurin-${cur}" "-eclipse-temurin-${latest}"

    success "Java version updated to ${latest}."
}

# ---------------------------------------------------------------------------
# 2) Maven version (full X.Y.Z)
# ---------------------------------------------------------------------------
update_maven_version() {
    section "Maven version"

    local -a current=()
    local v
    v="$(grep -oP '(?<=<maven-release>)[0-9]+\.[0-9]+\.[0-9]+(?=</maven-release>)' "${POM_FILE}" || true)"
    [ -n "${v}" ] && current+=("${v}")

    while IFS= read -r v; do
        [ -n "${v}" ] && current+=("${v}")
    done < <(grep -rhoP '(?<=maven-version: ")[0-9]+\.[0-9]+\.[0-9]+(?=")' "${WORKFLOW_DIR}" 2>/dev/null || true)

    v="$(grep -oP '(?<=maven:)[0-9]+\.[0-9]+\.[0-9]+' "${DOCKERFILE}" || true)"
    [ -n "${v}" ] && current+=("${v}")

    if [ "${#current[@]}" -eq 0 ]; then
        warn "Could not find any Maven version references; skipping."
        return 0
    fi

    local current_max
    current_max="$(printf '%s\n' "${current[@]}" | highest_version)"
    log "Current Maven versions referenced: ${current[*]} (highest: ${current_max})"

    # Stay within the current major line (project enforcer requires < next major).
    local major="${current_max%%.*}"

    # Latest released Maven version for that major, from Maven Central metadata.
    local latest
    latest="$(curl -fsSL https://repo1.maven.org/maven2/org/apache/maven/maven-core/maven-metadata.xml 2>/dev/null \
        | grep -oP '(?<=<version>)[^<]+(?=</version>)' \
        | grep -E "^${major}\.[0-9]+\.[0-9]+$" \
        | highest_version || true)"

    if ! [[ "${latest}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Could not determine latest Maven ${major}.x version; skipping."
        return 0
    fi
    log "Latest available Maven ${major}.x version: ${latest}"

    if ! version_gt "${latest}" "${current_max}"; then
        log "No Maven update available for all locations; leaving unchanged."
        return 0
    fi

    log "Updating Maven version to ${latest} in all locations."
    replace_in_file "${POM_FILE}" "<maven-release>${current[0]}</maven-release>" "<maven-release>${latest}</maven-release>"

    local f cur
    for f in "${WORKFLOW_DIR}"/*.y*ml; do
        [ -f "${f}" ] || continue
        while IFS= read -r cur; do
            replace_in_file "${f}" "maven-version: \"${cur}\"" "maven-version: \"${latest}\""
        done < <(grep -oP '(?<=maven-version: ")[0-9]+\.[0-9]+\.[0-9]+(?=")' "${f}" | sort -u)
    done

    cur="$(grep -oP '(?<=maven:)[0-9]+\.[0-9]+\.[0-9]+' "${DOCKERFILE}")"
    replace_in_file "${DOCKERFILE}" "maven:${cur}" "maven:${latest}"

    success "Maven version updated to ${latest}."
}

# ---------------------------------------------------------------------------
# 3) GitHub Actions versions (best effort)
# ---------------------------------------------------------------------------

# Resolve the latest release tag for an action repository (owner/repo).
latest_action_tag() {
    local repo="$1" tag=""

    if command -v gh >/dev/null 2>&1; then
        tag="$(gh api "repos/${repo}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
    fi

    if [ -z "${tag}" ]; then
        local auth=()
        [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        tag="$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null || true)"
    fi

    printf '%s' "${tag}"
}

update_github_actions() {
    section "GitHub Actions versions"

    [ -d "${WORKFLOW_DIR}" ] || { warn "No workflow directory; skipping."; return 0; }

    # Unique "owner/repo@ref" references across all workflows.
    local -a refs=()
    mapfile -t refs < <(grep -rhoP '(?<=uses: )[^@[:space:]]+@[^[:space:]]+' "${WORKFLOW_DIR}" | sort -u)

    if [ "${#refs[@]}" -eq 0 ]; then
        log "No action references found."
        return 0
    fi

    local ref repo current_ref latest f
    for ref in "${refs[@]}"; do
        repo="${ref%@*}"
        current_ref="${ref#*@}"

        # Skip local (./...) or docker (docker://...) references.
        case "${repo}" in
            ./*|docker:*) continue ;;
        esac

        latest="$(latest_action_tag "${repo}")"
        if [ -z "${latest}" ]; then
            warn "Could not resolve latest version for ${repo}; skipping (best effort)."
            continue
        fi

        if [ "${latest}" = "${current_ref}" ]; then
            log "${repo} already at ${current_ref}."
            continue
        fi

        log "Updating ${repo}: ${current_ref} -> ${latest}"
        for f in "${WORKFLOW_DIR}"/*.y*ml; do
            [ -f "${f}" ] || continue
            replace_in_file "${f}" "${repo}@${current_ref}" "${repo}@${latest}"
        done
    done

    success "GitHub Actions versions processed."
}

# ---------------------------------------------------------------------------
# 4) Git submodules (generic for any number defined in .gitmodules)
# ---------------------------------------------------------------------------
update_submodules() {
    section "Git submodules"

    if [ ! -f "${GITMODULES_FILE}" ]; then
        log "No ${GITMODULES_FILE}; nothing to update."
        return 0
    fi

    # Ensure submodules are present.
    git submodule update --init --recursive >/dev/null 2>&1 || true

    local -a paths=()
    mapfile -t paths < <(git config -f "${GITMODULES_FILE}" --get-regexp '\.path$' | awk '{print $2}')

    if [ "${#paths[@]}" -eq 0 ]; then
        log "No submodule paths defined."
        return 0
    fi

    local path latest_tag current_tag
    for path in "${paths[@]}"; do
        if [ ! -d "${path}/.git" ] && [ ! -f "${path}/.git" ]; then
            warn "Submodule '${path}' not initialised; skipping."
            continue
        fi

        log "Checking submodule '${path}' for the latest tag."
        (
            cd "${path}"
            git fetch --tags --quiet

            latest_tag="$(git describe --tags "$(git rev-list --tags --max-count=1)" 2>/dev/null || true)"
            current_tag="$(git describe --tags --exact-match 2>/dev/null || echo 'none')"

            if [ -z "${latest_tag}" ]; then
                warn "No tags found in submodule '${path}'; skipping."
                exit 0
            fi

            echo "  Latest tag:  ${latest_tag}"
            echo "  Current tag: ${current_tag}"

            if [ "${latest_tag}" != "${current_tag}" ]; then
                log "  Updating submodule '${path}' to ${latest_tag}"
                git checkout --quiet "${latest_tag}"
            else
                log "  Submodule '${path}' already at the latest tag."
            fi
        )
    done

    success "Submodules processed."
}

# ---------------------------------------------------------------------------
# 5) pom.xml dependencies (3PP libraries, plugin versions, etc.)
# ---------------------------------------------------------------------------
update_pom_dependencies() {
    section "pom.xml dependencies"

    if ! command -v mvn >/dev/null 2>&1; then
        warn "Maven (mvn) not found on PATH; skipping dependency update."
        return 0
    fi

    log "Running 'mvn versions:update-properties'."
    mvn -q versions:update-properties
    success "pom.xml dependency properties updated."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "Updating all project dependencies in ${REPO_ROOT}"

    update_java_version
    update_maven_version
    update_github_actions
    update_submodules
    update_pom_dependencies

    section "Done"
    success "All dependency update steps completed."
}

main "$@"
