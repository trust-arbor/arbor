defmodule Arbor.Common.ProjectContext do
  @moduledoc """
  Auto-loads `AGENTS.md` / `CLAUDE.md` project-context files into an agent's stable system
  prompt, matching the cross-tool `AGENTS.md` convention (Codex, opencode, Gemini CLI, openclaw
  all converge on this — researched 2026-07-03):

  - Walks from the working dir UP to the project root (nearest `.git`, or the workdir alone if no
    `.git` is found — Codex's rule), collecting at each level the FIRST of `["AGENTS.md",
    "CLAUDE.md"]` present (AGENTS.md wins per directory; the two never stack in one dir).
  - Prepends a GLOBAL home file: the first of the configured globals (default
    `~/.arbor/AGENTS.md` then `~/.claude/CLAUDE.md`).
  - Concatenates **global-first, then project root → cwd** (nearest content last = highest
    recency weight), each labeled with its source path, under a shared byte cap (default 32 KiB,
    like Codex; truncate the current file to the remaining budget, then skip the rest).

  Only reads files; returns the assembled string, or `""` when nothing is found. Meant to be
  prepended to the agent's stable/cacheable system prompt.
  """

  require Logger

  @project_filenames ["AGENTS.md", "CLAUDE.md"]
  @default_globals ["~/.arbor/AGENTS.md", "~/.claude/CLAUDE.md"]
  @default_max_bytes 32 * 1024
  @root_marker ".git"

  @doc """
  Load and concatenate project context for `workdir`.

  Options:
    * `:max_bytes` — shared budget across all files (default #{@default_max_bytes})
    * `:globals` — list of `~/`-expandable global file paths, first-present wins
      (default `#{inspect(@default_globals)}`)
    * `:filenames` — per-directory candidates, first-present wins (default
      `#{inspect(@project_filenames)}`)
  """
  @spec load(Path.t(), keyword()) :: String.t()
  def load(workdir, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    globals = Keyword.get(opts, :globals, @default_globals)
    filenames = Keyword.get(opts, :filenames, @project_filenames)

    (global_paths(globals) ++ project_paths(workdir, filenames))
    |> Enum.uniq()
    |> Enum.map(fn path -> {path, read(path)} end)
    |> Enum.reject(fn {_path, content} -> content == "" end)
    |> take_within_budget(max_bytes)
    |> Enum.map_join("\n\n", fn {path, content} -> label(path, content) end)
  rescue
    # Context loading must never break agent startup — fail open to "no context".
    e ->
      Logger.warning("[ProjectContext] load failed: #{Exception.message(e)}")
      ""
  end

  # --- global home file: first present of the configured list ---
  defp global_paths(globals) do
    globals
    |> Enum.map(&Path.expand/1)
    |> Enum.find(&File.regular?/1)
    |> List.wrap()
  end

  # --- project files: root → cwd, first-of-filenames per dir ---
  defp project_paths(workdir, filenames) do
    workdir
    |> Path.expand()
    |> dirs_root_to_cwd()
    |> Enum.map(&first_present(&1, filenames))
    |> Enum.reject(&is_nil/1)
  end

  # Dirs from the .git project root DOWN to workdir (inclusive), root first. No `.git` found →
  # just the workdir (Codex's "no marker → cwd only" rule), so we never slurp the whole FS.
  defp dirs_root_to_cwd(workdir) do
    case find_root(workdir) do
      nil -> [workdir]
      root -> path_from(root, workdir)
    end
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join(dir, @root_marker)) -> dir
      Path.dirname(dir) == dir -> nil
      true -> find_root(Path.dirname(dir))
    end
  end

  # [root, ..., leaf]; assumes leaf is at or under root.
  defp path_from(root, leaf) when root == leaf, do: [leaf]
  defp path_from(root, leaf), do: path_from(root, Path.dirname(leaf)) ++ [leaf]

  defp first_present(dir, filenames) do
    filenames
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.find(&File.regular?/1)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content)
      _ -> ""
    end
  end

  # Shared byte budget (like Codex): truncate the current file to what's left, skip once spent.
  defp take_within_budget(files, max_bytes) do
    {kept, _remaining} =
      Enum.reduce(files, {[], max_bytes}, fn
        {_path, _content}, {acc, remaining} when remaining <= 0 ->
          {acc, 0}

        {path, content}, {acc, remaining} ->
          if byte_size(content) <= remaining do
            {[{path, content} | acc], remaining - byte_size(content)}
          else
            truncated = binary_part(content, 0, remaining) <> "\n…[truncated]"
            {[{path, truncated} | acc], 0}
          end
      end)

    Enum.reverse(kept)
  end

  defp label(path, content) do
    "--- Context from: #{path} ---\n#{content}\n--- End of Context from: #{path} ---"
  end
end
