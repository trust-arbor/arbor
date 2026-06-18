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
end
