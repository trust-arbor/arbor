#!/usr/bin/env elixir

# Dumps the authoritative SKILL.md → DOT compilation system prompt
# from Arbor.Actions.Skill.CompilationPrompt into a text file consumable by promptfoo.
#
# Usage (from repo root, safe even with dev server running):
#   mix run --no-start evals/promptfoo/scripts/dump-compilation-prompt.exs
#
# Output:
#   evals/promptfoo/prompts/skill-to-dot-system.txt
#
# This keeps the single source of truth in the Elixir module while giving
# promptfoo a plain-text version for its config (no duplication of the long prompt).

# We deliberately avoid starting the application tree.
# The CompilationPrompt module has zero runtime dependencies.

Code.append_path("_build/dev/lib/arbor_actions/ebin")
Code.append_path("_build/dev/lib/arbor_contracts/ebin")

prompt_mod = Arbor.Actions.Skill.CompilationPrompt

unless Code.ensure_loaded?(prompt_mod) do
  IO.puts(:stderr, "ERROR: Could not load #{inspect(prompt_mod)}.")
  IO.puts(:stderr, "Try: mix compile (or mix compile --no-deps-check) first.")
  System.halt(1)
end

unless function_exported?(prompt_mod, :system_prompt, 0) do
  IO.puts(:stderr, "ERROR: #{inspect(prompt_mod)}.system_prompt/0 not found")
  System.halt(1)
end

prompt_text = apply(prompt_mod, :system_prompt, [])

out_path = "evals/promptfoo/prompts/skill-to-dot-system.txt"
File.mkdir_p!(Path.dirname(out_path))
File.write!(out_path, prompt_text)

IO.puts("Wrote #{byte_size(prompt_text)} bytes to #{out_path}")
IO.puts("Ready for promptfoo configs.")
