defmodule Arbor.Commands.SafeRecoveryArtifact do
  @moduledoc """
  E0B2C source-staging facade.

  Production `stage_source/1` binds HEAD, proves selected inputs, reconstructs
  the exact commit into an owner-private root, and returns a closed lease.
  C2/C3 consume that lease and call `release_source/1`. There is no cleanup
  callback.
  """

  alias Arbor.Commands.SafeRecoveryArtifact.{
    CleanupReceipt,
    ComposeFactInterpreter,
    ComposeShell,
    SourceStaging
  }

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

  @doc """
  Compose the E0B2C3b two-build safe-recovery artifact manifest.

  Accepted options: `:root` and `:timeout_ms` (the same closed source-staging
  policy as `stage_source/1`). Stages two independent source leases, requires
  their non-ephemeral facts to agree, acquires two independent owner-bound
  Shell trusted-build leases, requires their dependency inventories to agree
  before either build compiles, and projects the result through the existing
  E0B2B `SafeRecoveryArtifact.Core.project/1`.

  On every terminal path (success, error, throw, or exit) all acquired
  resources are cleaned up before returning. A retained cleanup failure is
  represented by `{:error, {:cleanup_retained, receipt}}` where `receipt` is
  a bounded, owner-bound, opaque `CleanupReceipt` -- resume with
  `retry_cleanup/1`. A prior unresolved receipt bounds retained authority to
  one outstanding episode per process: a second `compose/1` call returns
  `{:error, :cleanup_ledger_busy}` until the first is retried to resolution.
  """
  @spec compose(keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, {:cleanup_retained, CleanupReceipt.t()}}
  def compose(opts \\ [])

  def compose(opts) when is_list(opts), do: ComposeShell.compose(opts)
  def compose(_opts), do: {:error, :invalid_opts}

  @doc """
  Resume a retained two-build cleanup episode from the same process.

  Requires the exact `CleanupReceipt` struct returned by `compose/1`, issued
  from the same owner process, against a still-live ledger entry -- a foreign,
  forged, or already-fully-resolved receipt is rejected rather than
  reinterpreted as success. Returns the preserved original outcome only once
  every pending resource is proven cleaned.
  """
  @spec retry_cleanup(term()) ::
          {:ok, map()} | {:error, term()} | {:error, {:cleanup_retained, CleanupReceipt.t()}}
  def retry_cleanup(receipt), do: ComposeShell.retry_cleanup(receipt)

  @doc false
  @spec compose_from_facts_for_test(term()) ::
          {:ok, map()} | {:error, term()} | {:error, {:cleanup_retained, CleanupReceipt.t()}}
  def compose_from_facts_for_test(facts),
    do: ComposeFactInterpreter.compose_from_facts_for_test(facts)
end
