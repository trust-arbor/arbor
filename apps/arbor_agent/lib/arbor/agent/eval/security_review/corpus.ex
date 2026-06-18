defmodule Arbor.Agent.Eval.SecurityReview.Corpus do
  @moduledoc """
  Reconstructs the Security Sentinel L2-review eval corpus from a manifest of fix
  commits (see `Arbor.Agent.Eval.SecurityReview.Manifest`).

  For each item path it reads two snapshots straight out of git history:

    * **buggy**  — `git show <fix_commit>^:<path>` (the parent of the fix has the bug)
    * **fixed**  — `git show <fix_commit>:<path>`  (the fix)

  and writes them under `<output_dir>/<id>/{buggy,fixed}/<path>` plus a
  `manifest.json` describing the assembled corpus. The buggy snapshots are the
  inputs a reviewer is scored against (did it re-find the bug?); the fixed
  snapshots double as known-clean controls for precision/FP measurement.

  The git access is injected (`:git_reader`) so the assembly logic is unit-tested
  without touching a real repo. The default reader shells `git show` (System.cmd
  is fine for a dev/eval maintenance tool).

  Defensive: an item path that can't be read at the commit, or whose buggy and
  fixed snapshots are identical (so there is no bug to find — a mis-specified
  manifest entry), is dropped from the corpus and reported in `:skipped` rather
  than silently included.
  """

  alias Arbor.Agent.Eval.SecurityReview.Manifest

  @type git_reader :: (String.t(), String.t() -> {:ok, String.t()} | {:error, term()})

  @default_output_dir ".arbor/evals/security-review-corpus"

  @type built_item :: %{
          id: String.t(),
          category: atom(),
          fix_commit: String.t(),
          cross_file: boolean(),
          invariant: String.t(),
          files: [%{path: String.t(), buggy: String.t(), fixed: String.t()}],
          dir: String.t()
        }

  @type summary :: %{
          output_dir: String.t(),
          built: [String.t()],
          skipped: [%{id: String.t(), reason: term()}],
          item_count: non_neg_integer(),
          file_count: non_neg_integer()
        }

  @doc """
  Build the corpus from `items` (default `Manifest.items/0`).

  ## Options

    * `:output_dir` — where snapshots + `manifest.json` are written
      (default `#{@default_output_dir}`)
    * `:git_reader` — `(ref, path -> {:ok, content} | {:error, reason})`; the
      default shells `git show ref:path`. Injected in tests.
    * `:write?` — write snapshots/manifest to disk (default `true`; tests pass
      `false` to assert assembly without IO)

  Returns `{:ok, summary}`.
  """
  @spec build([map()] | nil, keyword()) :: {:ok, summary()}
  def build(items \\ nil, opts \\ []) do
    items = items || Manifest.items()
    output_dir = opts[:output_dir] || @default_output_dir
    git = opts[:git_reader] || (&default_git_read/2)
    write? = Keyword.get(opts, :write?, true)

    {built, skipped} =
      items
      |> Enum.map(&build_item(&1, output_dir, git))
      |> Enum.split_with(&match?({:ok, _}, &1))

    built_items = Enum.map(built, fn {:ok, item} -> item end)
    skipped_items = Enum.map(skipped, fn {:skip, info} -> info end)

    if write?, do: write_corpus(built_items, output_dir)

    {:ok,
     %{
       output_dir: output_dir,
       built: Enum.map(built_items, & &1.id),
       skipped: skipped_items,
       item_count: length(built_items),
       file_count: built_items |> Enum.flat_map(& &1.files) |> length()
     }}
  end

  # ---------------------------------------------------------------------------
  # Per-item assembly
  # ---------------------------------------------------------------------------

  defp build_item(%{id: id, fix_commit: commit, paths: paths} = item, output_dir, git) do
    dir = Path.join(output_dir, id)

    case resolve_files(commit, paths, git) do
      {:ok, files} ->
        {:ok,
         %{
           id: id,
           category: item[:category] || :other,
           fix_commit: commit,
           cross_file: item[:cross_file] || false,
           invariant: item[:invariant] || "",
           expected: item[:expected] || %{},
           verified: item[:verified] || false,
           files: files,
           dir: dir
         }}

      {:error, reason} ->
        {:skip, %{id: id, reason: reason}}
    end
  end

  defp build_item(item, _output_dir, _git),
    do: {:skip, %{id: item[:id] || "?", reason: :malformed}}

  # Resolve every path to a {buggy, fixed} snapshot pair. The whole item is
  # dropped if ANY path fails to read or shows no change (a no-op entry has no
  # bug to find — better to surface it than ship a vacuous corpus item).
  defp resolve_files(commit, paths, git) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, buggy} <- git.("#{commit}^", path),
           {:ok, fixed} <- git.(commit, path),
           :ok <- assert_changed(path, buggy, fixed) do
        {:cont, {:ok, [%{path: path, buggy: buggy, fixed: fixed} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      other -> other
    end
  end

  # resolve_files attaches the path to every error, so this returns the bare
  # reason (the path is added once, uniformly, alongside git read errors).
  defp assert_changed(_path, buggy, fixed) do
    if buggy == fixed, do: {:error, :no_change}, else: :ok
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp write_corpus(items, output_dir) do
    File.mkdir_p!(output_dir)

    Enum.each(items, fn item ->
      Enum.each(item.files, fn %{path: path, buggy: buggy, fixed: fixed} ->
        write_snapshot(item.dir, "buggy", path, buggy)
        write_snapshot(item.dir, "fixed", path, fixed)
      end)
    end)

    File.write!(Path.join(output_dir, "manifest.json"), encode_manifest(items))
  end

  defp write_snapshot(item_dir, kind, path, content) do
    dest = Path.join([item_dir, kind, path])
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, content)
  end

  defp encode_manifest(items) do
    items
    |> Enum.map(fn item ->
      %{
        id: item.id,
        category: item.category,
        fix_commit: item.fix_commit,
        cross_file: item.cross_file,
        invariant: item.invariant,
        expected: item.expected,
        verified: item.verified,
        files: Enum.map(item.files, & &1.path)
      }
    end)
    |> Jason.encode!(pretty: true)
  end

  # ---------------------------------------------------------------------------
  # Default git reader
  # ---------------------------------------------------------------------------

  @doc false
  @spec default_git_read(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def default_git_read(ref, path) do
    case System.cmd("git", ["show", "#{ref}:#{path}"], stderr_to_stdout: true) do
      {content, 0} -> {:ok, content}
      {err, _code} -> {:error, String.trim(err)}
    end
  end
end
