#!/usr/bin/env bash
# Migrate residual arcee-ai/trinity-large-preview:free references to the chosen
# replacement default model. Run AFTER the eval bake-off picks a winner.
#
# Usage:
#   scripts/migrate_trinity_refs.sh "nex-agi/nex-n2-pro:free"            # dry run
#   scripts/migrate_trinity_refs.sh "nex-agi/nex-n2-pro:free" --apply
#   scripts/migrate_trinity_refs.sh "nex-agi/nex-n2-pro:free" --apply --include-default
#
# --include-default also swaps config.exs default_model (currently
# openai/gpt-oss-120b:free). Without it, only trinity stragglers are replaced.
#
# After applying with a NEW model, add a ModelProfile catalog entry (the script
# reminds you; it does not auto-edit the catalog).
set -euo pipefail

NEW_MODEL="${1:?usage: $0 <new-model-id> [--apply] [--include-default]}"
APPLY=false; INCLUDE_DEFAULT=false
for a in "${@:2}"; do
  [ "$a" = "--apply" ] && APPLY=true
  [ "$a" = "--include-default" ] && INCLUDE_DEFAULT=true
done

OLD="arcee-ai/trinity-large-preview:free"
OLD_BARE="trinity-large-preview:free"

# Files with live or doc references to trinity (verified 2026-06-10).
FILES=(
  "apps/arbor_agent/lib/arbor/agent/spec.ex"                       # LIVE: agent default model_config
  "apps/arbor_common/lib/mix/tasks/arbor/doctor.ex"                # LIVE: doctor default map
  "apps/arbor_orchestrator/specs/pipelines/dev/homelab-handlers-port.dot"  # LIVE dev pipeline (x5)
  "apps/arbor_orchestrator/specs/pipelines/dev/skill-library.dot"  # LIVE-ish: embedded prompt would reintroduce trinity
  "apps/arbor_agent/lib/arbor/agent/api_config.ex"                 # doc examples
  "apps/arbor_agent/lib/arbor/agent/research_agent.ex"             # docstring
  "apps/arbor_common/lib/arbor/common/model_profile.ex"            # doc examples (catalog entry handled manually)
  "apps/arbor_orchestrator/specs/pipelines/eval-heartbeat.dot"     # comment example
  "apps/arbor_orchestrator/lib/mix/tasks/arbor.eval.ex"            # doc examples (bare form)
  "apps/arbor_ai/lib/arbor/ai.ex"                                  # doc example
  "apps/arbor_ai/test/arbor/ai/facade_migration_test.exs"          # test fixture
  "apps/arbor_ai/test/arbor_ai_test.exs"                           # test fixture
)

echo "Replacing: $OLD -> $NEW_MODEL"
$APPLY || echo "(dry run — pass --apply to write)"

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "  MISSING: $f"; continue; }
  count=$(grep -c "trinity-large-preview" "$f" || true)
  [ "$count" = "0" ] && { echo "  clean:   $f"; continue; }
  echo "  $count ref(s): $f"
  if $APPLY; then
    # Order matters: full id, bare id with :free, then bare doc mentions.
    sed -i.trinity-bak "s|$OLD|$NEW_MODEL|g; s|$OLD_BARE|${NEW_MODEL#*/}|g; s|trinity-large-preview|${NEW_MODEL#*/}|g" "$f"
    rm -f "$f.trinity-bak"
  fi
done

if $INCLUDE_DEFAULT; then
  echo "Swapping config.exs default_model -> $NEW_MODEL"
  if $APPLY; then
    sed -i.trinity-bak "s|default_model: \"openai/gpt-oss-120b:free\"|default_model: \"$NEW_MODEL\"|" config/config.exs
    rm -f config/config.exs.trinity-bak
    echo "  NOTE: update the comment above default_model with the eval evidence (run IDs)."
  fi
fi

echo ""
echo "POST-APPLY CHECKLIST:"
echo "  [ ] Add ModelProfile catalog entry for $NEW_MODEL (context_size, max_output_tokens, family)"
echo "      apps/arbor_common/lib/arbor/common/model_profile.ex (~line 120, next to gpt-oss entries)"
echo "  [ ] grep -rn 'trinity' config apps --include='*.ex' --include='*.exs' --include='*.dot' | grep -v _build"
echo "  [ ] mix test apps/arbor_common/test/arbor/common/model_profile_test.exs apps/arbor_ai/test"
echo "  [ ] Update .arbor/roadmap/0-inbox/default-model-retired-trinity-large-preview.md -> status: done"
