defmodule Arbor.Agent.Eval.SecurityReview.Tools do
  @moduledoc """
  Read-only, scope-confined navigation tools for the L2-review eval's **agentic**
  strategy — `list_files` / `read_file` / `search`, and nothing else.

  The hypothesis (after B-lite *hurt* the small model — attention dilution): give a
  small local model **agency** to pull in exactly the code it needs on demand,
  rather than dumping the whole subsystem. Safety comes from two constraints
  together, not just one:

    * **read-only** — no write, no execute, no shell. The tools can only read.
    * **path-scoped** — every path is resolved with `Arbor.Common.SafePath` against
      a single `scope_dir`; a traversal attempt (`../`, absolute path) returns an
      error, never a read outside scope.

  `for_scope/1` returns the `Arbor.LLM.Tool` list bound to one scope directory; the
  runner passes the corpus item's buggy-snapshot dir so the agent reviews the
  *buggy* code (not the fixed live tree).
  """

  alias Arbor.Common.SafePath
  alias Arbor.LLM.Tool

  @max_matches 60
  @max_file_bytes 200_000

  @doc "The read-only tool list confined to `scope_dir`."
  @spec for_scope(String.t()) :: [Tool.t()]
  def for_scope(scope_dir) do
    [
      %Tool{
        name: "list_files",
        description: "List the Elixir source files available for review (relative paths).",
        input_schema: %{"type" => "object", "properties" => %{}},
        execute: fn _args -> list_files(scope_dir) end
      },
      %Tool{
        name: "read_file",
        description: "Read one source file by its relative path (as returned by list_files).",
        input_schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        },
        execute: fn args -> read_file(scope_dir, args["path"] || args[:path]) end
      },
      %Tool{
        name: "search",
        description:
          "Search all in-scope files for a literal substring; returns matching file:line snippets.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"pattern" => %{"type" => "string"}},
          "required" => ["pattern"]
        },
        execute: fn args -> search(scope_dir, args["pattern"] || args[:pattern]) end
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Tool implementations (all read-only, all confined to scope_dir)
  # ---------------------------------------------------------------------------

  defp list_files(scope_dir) do
    files =
      scope_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, scope_dir))
      |> Enum.sort()

    %{files: files}
  end

  defp read_file(_scope_dir, path) when not is_binary(path),
    do: %{error: "read_file requires a string 'path'"}

  defp read_file(scope_dir, path) do
    case SafePath.safe_join(scope_dir, path) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, content} -> %{path: path, content: String.slice(content, 0, @max_file_bytes)}
          {:error, reason} -> %{error: "cannot read #{path}: #{inspect(reason)}"}
        end

      {:error, _} ->
        %{error: "path #{inspect(path)} is outside the review scope (denied)"}
    end
  end

  defp search(_scope_dir, pattern) when not is_binary(pattern) or pattern == "",
    do: %{error: "search requires a non-empty string 'pattern'"}

  defp search(scope_dir, pattern) do
    matches =
      scope_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn abs ->
        rel = Path.relative_to(abs, scope_dir)

        case File.read(abs) do
          {:ok, content} -> matches_in(content, pattern, rel)
          _ -> []
        end
      end)
      |> Enum.take(@max_matches)

    %{pattern: pattern, match_count: length(matches), matches: matches}
  end

  defp matches_in(content, pattern, rel) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> String.contains?(line, pattern) end)
    |> Enum.map(fn {line, n} -> %{file: rel, line: n, text: String.trim(line)} end)
  end
end
