#!/usr/bin/env bash
# Morning digest — meta-pipeline that consolidates today's overnight reports.
#
# Globs every report at ~/.arbor/reports/*/YYYY-MM-DD.md (skipping the
# digest itself), concatenates them with section headers, and writes a
# single digest at ~/.arbor/reports/morning-digest/YYYY-MM-DD.md. Designed
# to be invoked by morning_digest.dot, which is scheduled to fire after
# all the other overnight pipelines have completed.
#
# This MVP does plain concatenation — no LLM synthesis. The synthesis
# layer ("here are the three things you should care about") arrives when
# arbor_llm lands and the digest can call out to a summarization step.
# Until then the operator gets a single file to skim instead of N tabs.
#
# Self-test:
#     bash apps/arbor_scheduler/priv/scripts/morning_digest.sh

set -uo pipefail

REPORTS_ROOT="${HOME}/.arbor/reports"
DIGEST_DIR="${REPORTS_ROOT}/morning-digest"
DATE="$(date -u +%Y-%m-%d)"
DIGEST_PATH="${DIGEST_DIR}/${DATE}.md"

mkdir -p "${DIGEST_DIR}"

# Build in memory, write atomically at the end.
buf=""
append() { buf+="$1"$'\n'; }
append_file() {
    while IFS= read -r line; do
        append "${line}"
    done < "$1"
}

append "# Morning digest — ${DATE}"
append ""

# Collect today's reports from each topic. Each topic dir directly under
# ~/.arbor/reports/ holds files named YYYY-MM-DD.md. The digest itself is
# excluded so we don't recursively embed yesterday's-digest-in-today's.
reports=()
if [ -d "${REPORTS_ROOT}" ]; then
    while IFS= read -r -d '' candidate; do
        topic_dir="$(dirname "${candidate}")"
        topic="$(basename "${topic_dir}")"
        [ "${topic}" = "morning-digest" ] && continue
        reports+=("${candidate}")
    done < <(find "${REPORTS_ROOT}" -mindepth 2 -maxdepth 2 -type f -name "${DATE}.md" -print0 2>/dev/null)
fi

if [ "${#reports[@]}" -eq 0 ]; then
    append "_No reports landed today (${DATE})._"
    append ""
    append "Pipelines that would normally feed this digest:"
    append ""
    append "  - upstream-deps check"
    append "  - (others as they ship)"
    append ""
    append "If you expected reports today, check whether the scheduled jobs ran."
    append "Inspect with:"
    append ""
    append '```elixir'
    append '# In an iex --remsh attached to the running BEAM:'
    append 'Oban.Job |> Arbor.Persistence.Repo.all() |> Enum.take(-10)'
    append '```'
    append ""
else
    append "Reports included (${#reports[@]}):"
    append ""
    for report in "${reports[@]}"; do
        topic="$(basename "$(dirname "${report}")")"
        append "  - **${topic}** — \`${report}\`"
    done
    append ""
    append "---"
    append ""

    # Sort for stable output regardless of filesystem order.
    IFS=$'\n' sorted=($(sort <<<"${reports[*]}"))
    unset IFS

    for report in "${sorted[@]}"; do
        topic="$(basename "$(dirname "${report}")")"
        append "## ${topic}"
        append ""
        append "*Source: \`${report}\`*"
        append ""
        append_file "${report}"
        append ""
        append "---"
        append ""
    done
fi

append "_Digest generated at $(date -u +%Y-%m-%dT%H:%M:%SZ) by \`apps/arbor_scheduler/priv/scripts/morning_digest.sh\`._"

printf '%s' "${buf}" > "${DIGEST_PATH}"
echo "${DIGEST_PATH}"
