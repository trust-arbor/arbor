defmodule Arbor.Orchestrator.Eval.RunIdentity do
  @moduledoc """
  DEPRECATED: use `Arbor.Persistence` run-identity APIs instead.

  Thin compatibility delegate kept for one deprecation interval. All logic
  lives in `arbor_persistence` (`Arbor.Persistence` facade).
  """

  @doc "Merge run-identity fields into eval-run attrs."
  @spec capture(map()) :: map()
  def capture(attrs), do: Arbor.Persistence.capture_eval_run_identity(attrs)

  @doc "Current git HEAD sha, or nil if unavailable."
  @spec git_sha() :: String.t() | nil
  def git_sha, do: Arbor.Persistence.eval_git_sha()

  @doc "True if the working tree has uncommitted changes, nil if unknown."
  @spec git_dirty() :: boolean() | nil
  def git_dirty, do: Arbor.Persistence.eval_git_dirty()

  @doc "SHA-256 (hex, \"sha256:\" prefixed) of the dataset file at `path`."
  @spec dataset_hash(String.t() | nil) :: String.t() | nil
  def dataset_hash(path), do: Arbor.Persistence.eval_dataset_hash(path)

  @doc "Deterministic SHA-256 fingerprint of a config map (nil for nil/empty)."
  @spec config_fingerprint(map() | nil) :: String.t() | nil
  def config_fingerprint(config), do: Arbor.Persistence.eval_config_fingerprint(config)
end
