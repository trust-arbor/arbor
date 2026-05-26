#!/usr/bin/env elixir
#
# Build a JSON action index from apps/arbor_actions/lib/arbor/actions/*.ex
# source files. For each Jido sub-action (e.g., Arbor.Actions.File.Read),
# extract module name + first paragraph of @moduledoc as description.
#
# Then call Ollama embeddings API for each description, across three models:
# embeddinggemma (768), mxbai-embed-large (1024), nomic-embed-text (768).
#
# Output: priv/eval_datasets/preprocessor_tool_retrieval/action_index.json
#
# Usage:
#   elixir scripts/build_action_index.exs
#
# Run from the repo root.

Mix.install([
  {:jason, "~> 1.4"},
  {:req, "~> 0.5"}
])

defmodule BuildActionIndex do
  @ollama_url "http://localhost:11434/api/embeddings"
  @models ["embeddinggemma", "mxbai-embed-large", "nomic-embed-text"]
  @actions_root "apps/arbor_actions/lib/arbor/actions"
  @output "apps/arbor_orchestrator/priv/eval_datasets/preprocessor_tool_retrieval/action_index.json"

  def run do
    IO.puts("[1/3] Walking action source files...")
    files = walk_action_files()
    IO.puts("  Found #{length(files)} action source files")

    IO.puts("[2/3] Extracting modules + moduledocs...")
    actions = files |> Enum.flat_map(&extract_modules/1) |> Enum.uniq_by(& &1.module)
    IO.puts("  Extracted #{length(actions)} action modules")

    IO.puts("[3/3] Embedding descriptions across 3 models...")
    actions_with_embeddings = embed_all(actions)

    IO.puts("Writing index to #{@output}...")
    write_index(actions_with_embeddings)
    IO.puts("Done. #{length(actions_with_embeddings)} actions in index.")
  end

  defp walk_action_files do
    Path.wildcard(Path.join(@actions_root, "**/*.ex"))
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end

  defp extract_modules(path) do
    src = File.read!(path)

    # Match: defmodule X.Y.Z do  ... @moduledoc """..."""
    # Allow blank lines and `use`/`alias` etc. between defmodule and @moduledoc.
    # We accept up to ~30 lines of header content before the moduledoc.
    pattern = ~r/defmodule\s+(Arbor\.Actions(?:\.[A-Z]\w*)+)\s+do\b(?:[^\n]*\n){0,30}?\s*@moduledoc\s+"""(.*?)"""/s

    top_level = extract_with(pattern, src, path)

    # Also extract nested sub-action @docs (e.g., `def run(...)` actions with @doc strings).
    # These don't have @moduledoc but they're the actual Jido actions with distinctive
    # per-action descriptions.
    sub_actions = extract_sub_actions(src, top_level)

    top_level ++ sub_actions
  end

  defp extract_with(pattern, src, path) do
    Regex.scan(pattern, src)
    |> Enum.map(fn [_full, module, doc] ->
      %{
        module: module,
        description: clean_text(doc),
        source_file: path
      }
    end)
    |> Enum.reject(&(&1.description == ""))
  end

  # Extract nested `defmodule X.Sub do @moduledoc "..."` patterns that the top-level
  # regex didn't capture (e.g., Arbor.Actions.File.Read with its own @moduledoc).
  defp extract_sub_actions(src, top_level_modules) do
    captured = MapSet.new(top_level_modules, & &1.module)

    # Match nested defmodule occurrences. Use a more permissive pattern that captures
    # ANY Arbor.Actions.X.Y form, even if not at file top level.
    pattern = ~r/defmodule\s+([A-Z]\w*(?:\.[A-Z]\w*)+)\s+do\b(?:[^\n]{0,200}\n){0,20}?\s*@moduledoc\s+"""(.*?)"""/s

    Regex.scan(pattern, src)
    |> Enum.map(fn [_full, name, doc] ->
      %{name: name, description: clean_text(doc)}
    end)
    |> Enum.reject(fn %{name: n, description: d} ->
      # Skip names already captured at top level, and skip empty descriptions.
      MapSet.member?(captured, n) or d == ""
    end)
    |> Enum.map(fn %{name: n, description: d} ->
      # Sub-actions inside a parent module are unqualified (e.g., `defmodule Read do`
      # inside `Arbor.Actions.File`). We can't easily reconstruct the FQN from regex,
      # so we just include them as their unqualified name — they'll appear as
      # extra entries in the index. For first eval that's OK; the prompt-to-URI
      # mapping in the corpus uses top-level modules.
      %{module: n, description: d, source_file: nil}
    end)
  end

  # Take the full moduledoc but strip the most problematic markdown noise:
  # - Code blocks (```...```)
  # - HTML-ish entities
  # - Long horizontal rules (---)
  # Keep tables (they often contain useful action lists) but strip the pipe scaffolding.
  # Truncate to ~2000 chars to stay safely under embedding model context limits.
  defp clean_text(text) do
    text
    |> String.trim()
    # Strip fenced code blocks entirely — they don't add semantic signal for retrieval.
    |> String.replace(~r/```[\s\S]*?```/, " ")
    # Strip section headers' ## marks but keep the header text.
    |> String.replace(~r/^#+\s+/m, "")
    # Strip table pipe characters (keep cell content joined by spaces).
    |> String.replace(~r/\s*\|\s*/, " ")
    # Strip table separator rows like "|---|---|".
    |> String.replace(~r/^[\s\-:]+$/m, "")
    # Strip horizontal rules.
    |> String.replace(~r/^---+$/m, "")
    # Squash multiple newlines and surrounding whitespace.
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(2000)
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: binary_part(s, 0, max)

  defp embed_all(actions) do
    total = length(actions)

    actions
    |> Enum.with_index(1)
    |> Enum.map(fn {action, idx} ->
      IO.write("  [#{idx}/#{total}] #{action.module} ... ")

      embeddings =
        @models
        |> Enum.map(fn model ->
          {model, embed(model, action.description)}
        end)
        |> Enum.into(%{})

      IO.puts("done")
      Map.put(action, :embeddings, embeddings)
    end)
  end

  defp embed(model, text) do
    case Req.post(@ollama_url, json: %{model: model, prompt: text}, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"embedding" => vec}}} ->
        vec

      {:ok, %{status: status, body: body}} ->
        IO.warn("Embedding failed for #{model}: #{status} #{inspect(body)}")
        nil

      {:error, reason} ->
        IO.warn("Embedding error for #{model}: #{inspect(reason)}")
        nil
    end
  end

  defp write_index(actions) do
    File.mkdir_p!(Path.dirname(@output))

    payload = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      models: @models,
      action_count: length(actions),
      actions: actions
    }

    File.write!(@output, Jason.encode!(payload, pretty: true))
  end
end

BuildActionIndex.run()
