defmodule Arbor.Commands.SafeRecoveryArtifact do
  @moduledoc """
  E0B2C source-staging facade.

  Production `stage_source/1` binds HEAD, proves selected inputs, reconstructs
  the exact commit into an owner-private root, and returns a closed lease.
  C2/C3 consume that lease and call `release_source/1`. There is no cleanup
  callback.
  """

  alias Arbor.Commands.SafeRecoveryArtifact.SourceStaging

  @doc """
  Stage the fixed E0B2C source inputs from a trusted umbrella root.

  Accepted options: `:root` and `:timeout_ms`.
  """
  @spec stage_source(keyword()) :: {:ok, map()} | {:error, term()}
  def stage_source(opts \\ [])

  def stage_source(opts) when is_list(opts), do: SourceStaging.stage(opts, :production)
  def stage_source(_opts), do: {:error, :invalid_opts}

  @doc false
  @spec stage_source_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def stage_source_for_test(opts \\ [])

  def stage_source_for_test(opts) when is_list(opts), do: SourceStaging.stage(opts, :test)
  def stage_source_for_test(_opts), do: {:error, :invalid_opts}

  @doc "Release a source lease after verified owned-tree cleanup."
  @spec release_source(term()) :: :ok | {:error, term()}
  def release_source(lease), do: SourceStaging.release(lease)

  @doc false
  @spec release_source_for_test(term()) :: :ok | {:error, term()}
  def release_source_for_test(lease), do: SourceStaging.release_for_test(lease)

  @doc false
  @spec release_source_for_test(term(), :force_cleanup_failure) :: :ok | {:error, term()}
  def release_source_for_test(lease, :force_cleanup_failure),
    do: SourceStaging.release_for_test(lease, :force_cleanup_failure)

  def release_source_for_test(_lease, _fault), do: {:error, :invalid_opts}
end
