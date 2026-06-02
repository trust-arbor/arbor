#!/usr/bin/env bash
# Upstream deps check — first reference pipeline for Arbor.Scheduler.
#
# Reads a list of local git repos to check from ~/.arbor/upstream_deps.conf
# (one absolute path per line, blank lines and `#` comments ignored), runs
# `git fetch` against each one, and produces a markdown report at
# ~/.arbor/reports/upstream-deps/YYYY-MM-DD.md showing what's new upstream
# since the local HEAD.
#
# Designed to be invoked by the upstream_deps_check.dot pipeline, which is
# in turn scheduled by Oban via the Arbor.Scheduler cron table. Also
# runnable directly from a shell for development:
#
#     bash apps/arbor_scheduler/priv/scripts/upstream_deps_check.sh
#
# The script is intentionally self-contained — no Arbor dependency, no
# Elixir runtime needed. The orchestrator's shell handler just runs it as
# a subprocess and captures the report path on completion. Categorizing
# the deltas (security / breaking / feature / cosmetic) via LLM is a
# follow-up — for the MVP the agent reading the report does that
# categorization itself.

set -uo pipefail

CONFIG_FILE="${HOME}/.arbor/upstream_deps.conf"
REPORT_DIR="${HOME}/.arbor/reports/upstream-deps"
DATE="$(date -u +%Y-%m-%d)"
REPORT_PATH="${REPORT_DIR}/${DATE}.md"

mkdir -p "${REPORT_DIR}"

# All output is built up in $buf and written atomically at the end. Keeps
# the "no config file" branch clean and avoids a half-written report on
# disk if the script is interrupted.
buf=""
append() { buf+="$1"$'\n'; }
append_lines() {
    while IFS= read -r line; do
        append "${line}"
    done
}

append "# Upstream deps check — ${DATE}"
append ""

if [ ! -f "${CONFIG_FILE}" ]; then
    append "**No config file at \`${CONFIG_FILE}\`.**"
    append ""
    append "Create it with one repo path per line, e.g.:"
    append ""
    append '```'
    append '# Comments and blank lines are ignored.'
    append '/Users/you/code/hermes-agent'
    append '/Users/you/code/openclaw'
    append '/Users/you/code/req_llm'
    append '```'
    append ""
    printf '%s' "${buf}" > "${REPORT_PATH}"
    echo "${REPORT_PATH}"
    exit 0
fi

repo_count=0
ahead_count=0  # cumulative count of commits the local clone is BEHIND upstream

while IFS= read -r line || [ -n "${line}" ]; do
    # Strip comments + trim whitespace.
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "${line}" ] && continue

    repo_count=$((repo_count + 1))
    repo_path="${line/#\~/${HOME}}"

    if [ ! -d "${repo_path}/.git" ]; then
        append "## ${line}"
        append ""
        append "*Not a git repo (path does not exist or has no .git/).*"
        append ""
        continue
    fi

    name="$(basename "${repo_path}")"
    append "## ${name}"
    append ""
    append "Path: \`${repo_path}\`"
    append ""

    # Fetch quietly. Capture stderr so auth / network errors land in the
    # report rather than disappearing.
    fetch_err="$(git -C "${repo_path}" fetch --quiet 2>&1)" || true
    if [ -n "${fetch_err}" ]; then
        append '**Fetch warnings/errors:**'
        append ''
        append '```'
        append "${fetch_err}"
        append '```'
        append ''
    fi

    # Pick the tracking branch — usually origin/HEAD, fall back to common names.
    upstream="$(git -C "${repo_path}" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)"
    if [ -z "${upstream}" ]; then
        for cand in origin/main origin/master; do
            if git -C "${repo_path}" rev-parse --verify "${cand}" >/dev/null 2>&1; then
                upstream="${cand}"
                break
            fi
        done
    fi

    if [ -z "${upstream}" ]; then
        append "*No upstream branch found.*"
        append ""
        continue
    fi

    # rev-list --count A..B counts commits IN B but NOT IN A.
    # "HEAD..upstream" → commits in upstream not yet in HEAD → we are BEHIND by this many.
    # "upstream..HEAD" → commits in HEAD not yet in upstream → we are AHEAD by this many.
    behind="$(git -C "${repo_path}" rev-list --count "HEAD..${upstream}" 2>/dev/null || echo 0)"
    ahead="$(git -C "${repo_path}" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"

    append "Upstream: \`${upstream}\`"
    append ""
    append "Local is **${behind} commits behind** upstream, **${ahead} commits ahead**."
    append ""

    if [ "${behind}" -gt 0 ] 2>/dev/null; then
        ahead_count=$((ahead_count + behind))
        append "### New upstream commits (${behind}):"
        append ""
        append '```'
        # Cap at 50 to keep daily reports readable.
        git -C "${repo_path}" log --oneline --no-decorate \
            "HEAD..${upstream}" -n 50 2>/dev/null \
            | append_lines
        append '```'
        append ""
    else
        append "_Up to date._"
        append ""
    fi
done < "${CONFIG_FILE}"

append "---"
append ""
append "Checked ${repo_count} repo(s), ${ahead_count} new upstream commit(s) total."
append ""
append "_Generated by \`apps/arbor_scheduler/priv/scripts/upstream_deps_check.sh\` at $(date -u +%Y-%m-%dT%H:%M:%SZ)._"

printf '%s' "${buf}" > "${REPORT_PATH}"

# The script's stdout (consumed by the orchestrator's shell handler and
# stored under shell.<node_id>.output) is just the report path. Downstream
# nodes — a future digest aggregator, a notification, etc. — can use it to
# find the artifact this run produced.
echo "${REPORT_PATH}"
