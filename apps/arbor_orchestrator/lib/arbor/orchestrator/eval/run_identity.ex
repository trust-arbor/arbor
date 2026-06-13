defmodule Arbor.Orchestrator.Eval.RunIdentity do
  @moduledoc """
  Captures run-identity fields for eval runs so results are longitudinally
  comparable: which code (git sha), which exact dataset contents (file hash),
  and which configuration (fingerprint) produced a result.

  Motivation: "did this change improve the system?" is only answerable when
  every run is bound to the commit, dataset version, and config it ran
  against. See `.arbor/roadmap/1-brainstorming/eval-system-architecture.md`.

  All capture is best-effort and fail-safe: any failure (no git binary,
  detached worktree, missing dataset file) simply omits the field — an eval
  run must never fail because identity capture failed. Caller-provided
  values are never overwritten.

  Fields the caller should provide directly (not derivable here): `quant`,
  `endpoint`, `layer`, `task_id`.
  """

  @doc """
  Merge run-identity fields into eval-run attrs.

  Adds (when derivable and not already present):

    - `:git_sha` / `:git_dirty` — HEAD commit and working-tree state
    - `:dataset_hash` — SHA-256 of the dataset file (`attrs[:dataset]` path)
    - `:config_fingerprint` — SHA-256 over the deterministic external term
      format of `attrs[:config]`

  ## Examples

      iex> attrs = RunIdentity.capture(%{id: "run1", dataset: "priv/eval_datasets/chat_quality.jsonl", config: %{timeout: 60}})
      iex> is_binary(attrs[:git_sha]) or is_nil(attrs[:git_sha])
      true
  """
  @spec capture(map()) :: map()
  def capture(attrs) when is_map(attrs) do
    attrs
    |> put_new_lazy_safe(:git_sha, &git_sha/0)
    |> put_new_lazy_safe(:git_dirty, &git_dirty/0)
    |> put_new_lazy_safe(:dataset_hash, fn -> dataset_hash(attrs[:dataset]) end)
    |> put_new_lazy_safe(:config_fingerprint, fn -> config_fingerprint(attrs[:config]) end)
  end

  @doc "Current git HEAD sha, or nil if unavailable."
  @spec git_sha() :: String.t() | nil
  def git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "True if the working tree has uncommitted changes, nil if unknown."
  @spec git_dirty() :: boolean() | nil
  def git_dirty do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  SHA-256 (hex, "sha256:" prefixed) of the dataset file at `path`.
  Returns nil when the path is missing or unreadable.
  """
  @spec dataset_hash(String.t() | nil) :: String.t() | nil
  def dataset_hash(nil), do: nil

  def dataset_hash(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def dataset_hash(_), do: nil

  @doc """
  Deterministic SHA-256 fingerprint of a config map (nil for nil/empty).

  Uses `:erlang.term_to_binary/2` with the `:deterministic` option so map
  key ordering cannot change the fingerprint.
  """
  @spec config_fingerprint(map() | nil) :: String.t() | nil
  def config_fingerprint(nil), do: nil
  def config_fingerprint(config) when config == %{}, do: nil

  def config_fingerprint(config) when is_map(config) do
    binary = :erlang.term_to_binary(config, [:deterministic])
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
  rescue
    _ -> nil
  end

  def config_fingerprint(_), do: nil

  # Put key only if absent AND the computed value is non-nil. Never raises.
  defp put_new_lazy_safe(attrs, key, fun) do
    if Map.has_key?(attrs, key) do
      attrs
    else
      case fun.() do
        nil -> attrs
        value -> Map.put(attrs, key, value)
      end
    end
  rescue
    _ -> attrs
  end
end
