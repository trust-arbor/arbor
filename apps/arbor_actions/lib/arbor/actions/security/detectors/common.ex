defmodule Arbor.Actions.Security.Detectors.Common do
  @moduledoc """
  Shared helper idioms for the Security Sentinel's static / whole-tree detectors.

  These were copy-pasted across `StaticScan` and the L0b detectors
  (`SignedFieldCoverage`, `UriRegistration`, `DependencyScan`, `UriInventory`).
  Centralizing them here is a behavior-preserving de-duplication that prepares
  for generated detectors — every helper keeps the exact semantics each caller
  relied on (see the per-function docs for the one place behavior is
  parameterized).
  """

  @doc """
  Extract the umbrella app name from a `apps/<name>/...` path.

  Returns the captured app name, or `default` (default `nil`) when the path is
  not under `apps/`. `DependencyScan` passes `default: "umbrella"` for repo-root
  `mix.exs`; every other caller relies on the `nil` default.
  """
  @spec library_of(String.t(), nil | String.t()) :: nil | String.t()
  def library_of(file, default \\ nil) do
    case Regex.run(~r{apps/([^/]+)/}, file) do
      [_, lib] -> lib
      _ -> default
    end
  end

  @doc """
  All non-test Elixir source files under `root`.

  `Path.wildcard(root/**/*.ex)` minus anything under a `/test/` directory —
  the exact enumeration the whole-tree detectors walk.
  """
  @spec elixir_source_files(String.t()) :: [String.t()]
  def elixir_source_files(root) do
    Path.wildcard(Path.join(root, "**/*.ex"))
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end

  @doc """
  Read `path` and parse it to a quoted AST.

  Returns `{:ok, ast}` / `{:error, _}` (or the `File.read` error). `opts` are
  passed straight through to `Code.string_to_quoted/2`; the default is the bare
  form. Callers that need source line/column metadata pass `columns: true` —
  matching their prior behavior exactly (do not change a caller's opts, since
  parse metadata feeds finding locations / dedup keys).
  """
  @spec parse(String.t(), keyword()) :: {:ok, Macro.t()} | {:error, term()}
  def parse(path, opts \\ []) do
    with {:ok, code} <- File.read(path) do
      Code.string_to_quoted(code, opts)
    end
  end

  @doc """
  The source of the `def`/`defp` clause `function` enclosing `line` in `file`.

  Captured so downstream consumers (the Sentinel's detector-synthesis G4 stage)
  can pin a real positive/FP-regression test to the *actual* flagged code rather
  than a synthetic fallback. The matching clause's AST is re-rendered via
  `Macro.to_string/1`, which is guaranteed self-contained and parseable (the S1
  G4 test `Code.string_to_quoted!`s it) — unlike a raw line-slice, which can clip
  the trailing `end`.

  Picks the clause whose start line is the greatest at or before `line` (the one
  the violation sits in); falls back to the earliest clause of that name when
  none precede `line`. Returns `nil` when `function` is nil/unknown or the file
  can't be parsed (excerpt is best-effort, never raises).
  """
  @spec code_excerpt(String.t(), String.t() | atom() | nil, non_neg_integer() | nil) ::
          String.t() | nil
  def code_excerpt(_file, nil, _line), do: nil

  def code_excerpt(file, function, line) do
    with {:ok, ast} <- parse(file, columns: true),
         node when not is_nil(node) <- enclosing_def(ast, to_string(function), line) do
      Macro.to_string(node)
    else
      _ -> nil
    end
  end

  defp enclosing_def(ast, function, line) do
    {_, matches} =
      Macro.prewalk(ast, [], fn
        {def_kw, meta, [head, body]} = node, acc
        when def_kw in [:def, :defp] and is_list(body) ->
          if def_name(head) == function,
            do: {node, [{meta[:line] || 0, node} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    case matches do
      [] ->
        nil

      _ ->
        at_or_before = Enum.filter(matches, fn {l, _} -> is_nil(line) or l <= line end)
        pool = if at_or_before == [], do: matches, else: at_or_before
        {_line, node} = Enum.max_by(pool, fn {l, _} -> l end)
        node
    end
  end

  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: to_string(name)
  defp def_name(_), do: nil
end
