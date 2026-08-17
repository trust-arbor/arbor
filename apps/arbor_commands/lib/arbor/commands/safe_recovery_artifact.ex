defmodule Arbor.Commands.SafeRecoveryArtifact do
  @moduledoc """
  E0B2C source-staging facade plus the E0B2C3c1 committed-artifact surfaces.

  Production `stage_source/1` binds HEAD, proves selected inputs, reconstructs
  the exact commit into an owner-private root, and returns a closed lease.
  C2/C3 consume that lease and call `release_source/1`. There is no cleanup
  callback.

  `compose/1` composes the two-build artifact manifest.
  `report/1`, `check/1`, `build_verify/1`, and `write/1` admit, bind, verify,
  and (for write only) publish the committed artifact pair at the two
  SourcePolicy-excluded committed paths. Write takes no caller-selected
  destination, digest, hook, or override.
  """

  alias Arbor.Commands.SafeRecoveryArtifact.{
    BuildVerifyCore,
    CheckCore,
    CleanupReceipt,
    CommittedStore,
    ComposeFactInterpreter,
    ComposeShell,
    Encode,
    Envelope,
    InputEvidence,
    SourceStaging
  }

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Common.SafePath

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

  # -- E0B2C3c1 committed artifact surfaces ---------------------------------

  @report_opt_keys MapSet.new([:json, :root])
  @live_opt_keys MapSet.new([:json, :root, :timeout_ms])
  @check_test_opt_keys MapSet.union(@live_opt_keys, MapSet.new([:overlay_size, :overlay_sha256]))
  @default_live_opts %{json: false, root: nil, timeout_ms: 300_000}
  @max_timeout_ms 3_600_000

  @doc """
  Report the committed safe-recovery artifact evidence.

  Reads and admits only the two committed artifact files. Accepted options:
  `:json` and `:root`. Never writes and never nests a trusted-build.
  """
  @spec report(keyword()) :: {:ok, map()} | {:error, term()}
  def report(opts \\ [])

  def report(opts) when is_list(opts) do
    with {:ok, admitted} <- admit_opts(opts, @report_opt_keys, %{json: false, root: nil}),
         {:ok, root} <- resolve_root(admitted.root),
         {:ok, artifact} <- load_artifact(root) do
      artifact_result("report", admitted.json, artifact)
    end
  end

  def report(_opts), do: {:error, :invalid_opts}

  @doc """
  Check the committed artifact against the complete fixed input set at HEAD.

  Accepted options: `:json`, `:root`, and `:timeout_ms`. Cheap and complete:
  every SourcePolicy-selected HEAD blob plus the pinned native overlay must
  bind exactly. Never writes and never nests a trusted-build.
  """
  @spec check(keyword()) :: {:ok, map()} | {:error, term()}
  def check(opts \\ [])

  def check(opts) when is_list(opts), do: run_check(opts, :production)

  def check(_opts), do: {:error, :invalid_opts}

  @doc false
  @spec check_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def check_for_test(opts) when is_list(opts), do: run_check(opts, :test)

  def check_for_test(_opts), do: {:error, :invalid_opts}

  defp run_check(opts, kind) do
    allowed = if kind == :test, do: @check_test_opt_keys, else: @live_opt_keys

    with {:ok, admitted} <- admit_opts(opts, allowed, @default_live_opts),
         {:ok, root} <- resolve_root(admitted.root),
         {:ok, artifact} <- load_artifact(root),
         {:ok, _} <- CheckCore.admit_for_check(artifact_input(artifact)),
         {:ok, observed} <- observe_inputs(root, admitted) do
      committed = build_input_list(artifact)

      with :ok <- CheckCore.compare_inputs(committed, observed.inputs),
           {:ok, base} <- artifact_result("check", admitted.json, artifact) do
        {:ok,
         Map.merge(base, %{
           "inputs_checked" => length(observed.inputs),
           "head_commit" => observed.commit,
           "head_tree" => observed.tree
         })}
      end
    end
  end

  @doc """
  Verify the committed artifact against a fresh production two-build compose.

  Accepted options: `:json`, `:root`, and `:timeout_ms`. Never writes.
  """
  @spec build_verify(keyword()) :: {:ok, map()} | {:error, term()}
  def build_verify(opts \\ [])

  def build_verify(opts) when is_list(opts) do
    with {:ok, admitted} <- admit_opts(opts, @live_opt_keys, @default_live_opts),
         {:ok, root} <- resolve_root(admitted.root),
         {:ok, artifact} <- load_artifact(root),
         {:ok, _} <- CheckCore.admit_for_check(artifact_input(artifact)) do
      compose(root: root, timeout_ms: admitted.timeout_ms)
      |> verify_fresh(Map.fetch!(artifact, :manifest))
      |> case do
        {:ok, extras} ->
          with {:ok, base} <- artifact_result("build_verify", admitted.json, artifact) do
            {:ok, Map.merge(base, extras)}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  def build_verify(_opts), do: {:error, :invalid_opts}

  @doc """
  Compose the two-build artifact and write exactly the two committed paths.

  Accepted options: `:json`, `:root`, and `:timeout_ms`. There is no
  caller-selected destination: the only files ever created or replaced are
  the two SourcePolicy-excluded committed artifact paths.
  """
  @spec write(keyword()) :: {:ok, map()} | {:error, term()}
  def write(opts \\ [])

  def write(opts) when is_list(opts) do
    with {:ok, admitted} <- admit_opts(opts, @live_opt_keys, @default_live_opts),
         {:ok, root} <- resolve_root(admitted.root),
         {:ok, manifest} <-
           compose(root: root, timeout_ms: admitted.timeout_ms) do
      publish_manifest(manifest, root, "write", admitted.json)
    end
  end

  def write(_opts), do: {:error, :invalid_opts}

  @doc false
  @spec write_from_manifest_for_test(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write_from_manifest_for_test(manifest, opts) when is_map(manifest) and is_list(opts) do
    with {:ok, admitted} <- admit_opts(opts, @report_opt_keys, %{json: false, root: nil}),
         {:ok, root} <- resolve_root(admitted.root),
         :ok <- Encode.validate_manifest(manifest) do
      publish_manifest(manifest, root, "write", admitted.json)
    end
  end

  def write_from_manifest_for_test(_manifest, _opts), do: {:error, :invalid_opts}

  # -- shared artifact pipeline --------------------------------------------

  defp publish_manifest(manifest, root, mode, json) do
    with :ok <- require_identical(manifest),
         {:ok, payload_bytes} <- Encode.encode_manifest(manifest),
         {:ok, envelope} <- Envelope.build(payload_bytes),
         {:ok, envelope_bytes} <- Envelope.encode(envelope),
         :ok <- require_destinations_bound(),
         :ok <- CommittedStore.write(root, envelope_bytes, payload_bytes),
         {:ok, artifact} <- load_artifact(root),
         {:ok, _} <- CheckCore.admit_for_check(artifact_input(artifact)),
         {:ok, base} <- artifact_result(mode, json, artifact) do
      {:ok, Map.merge(base, %{"written_paths" => CommittedStore.paths()})}
    end
  end

  defp require_destinations_bound do
    if CommittedStore.paths_bound_to_source_policy?(),
      do: :ok,
      else: {:error, :destination_policy_drift}
  end

  defp verify_fresh({:ok, fresh}, committed) do
    with :ok <- require_identical(fresh),
         :ok <- BuildVerifyCore.equal_evidence(committed, fresh),
         {:ok, committed_digest} <- Encode.manifest_digest(committed),
         {:ok, fresh_digest} <- Encode.manifest_digest(fresh) do
      {:ok,
       %{
         "committed_manifest_digest" => committed_digest,
         "fresh_manifest_digest" => fresh_digest,
         "committed_source_commit" => committed["source"]["commit"],
         "fresh_source_commit" => fresh["source"]["commit"],
         "equality" => "verified"
       }}
    end
  end

  defp verify_fresh({:error, _reason} = error, _committed), do: error

  defp require_identical(%{"reproducibility" => %{"status" => "identical"}}), do: :ok
  defp require_identical(_manifest), do: {:error, :reproducibility_mismatch}

  defp artifact_input(%{envelope: envelope, manifest: manifest}),
    do: %{envelope_map: envelope, manifest_map: manifest}

  defp build_input_list(%{manifest: manifest}) do
    manifest |> Map.fetch!("source") |> Map.fetch!("build_inputs")
  end

  defp observe_inputs(root, admitted) do
    overlay = overlay_expectation(admitted)
    InputEvidence.observe(root, admitted.timeout_ms, overlay)
  end

  defp overlay_expectation(%{overlay_size: size, overlay_sha256: digest})
       when is_integer(size) and size > 0 and is_binary(digest),
       do: {:expected, size, digest}

  defp overlay_expectation(_admitted), do: :production

  defp load_artifact(root) do
    with {:ok, %{envelope_bytes: envelope_bytes, payload_bytes: payload_bytes}} <-
           CommittedStore.read(root),
         {:ok, envelope_map} <-
           decode_map(envelope_bytes, :invalid_envelope_json, :invalid_envelope_shape),
         {:ok, manifest_map} <-
           decode_map(payload_bytes, :invalid_payload_json, :invalid_payload_shape),
         {:ok, admitted} <-
           CheckCore.admit_artifact(%{envelope_map: envelope_map, manifest_map: manifest_map}),
         :ok <- CheckCore.bind_payload_bytes(envelope_map, payload_bytes) do
      {:ok, admitted}
    end
  end

  defp decode_map(bytes, json_error, shape_error) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = map} when not is_struct(map) -> {:ok, map}
      {:ok, _other} -> {:error, shape_error}
      {:error, _reason} -> {:error, json_error}
    end
  end

  defp decode_map(_bytes, _json_error, _shape_error), do: {:error, :invalid_manifest}

  defp artifact_result(mode, json, %{envelope: envelope, manifest: manifest}) do
    with {:ok, manifest_digest} <- Encode.manifest_digest(manifest) do
      payload = Map.fetch!(envelope, "payload")

      {:ok,
       %{
         "mode" => mode,
         "output" => if(json, do: "json", else: "human"),
         "schema" => Map.fetch!(manifest, "schema"),
         "manifest_digest" => manifest_digest,
         "payload_sha256" => Map.fetch!(payload, "sha256"),
         "payload_byte_size" => Map.fetch!(payload, "byte_size"),
         "findings_count" => length(Map.fetch!(manifest, "findings")),
         "reproducibility_status" => manifest["reproducibility"]["status"]
       }}
    end
  end

  defp resolve_root(path) do
    with {:ok, root} <- PackagingRoot.resolve(path),
         :ok <- reject_root_symlink(root),
         {:ok, real} <- SafePath.resolve_real(root) do
      {:ok, real}
    else
      {:error, :not_found} -> {:error, :invalid_root_marker}
      {:error, :umbrella_root_not_found} -> {:error, :invalid_root_marker}
      {:error, :invalid_root_marker} = error -> error
      {:error, :root_symlink_redirection} = error -> error
      {:error, _} -> {:error, :invalid_root}
    end
  end

  defp reject_root_symlink(root) do
    case File.read_link(root) do
      {:ok, _} -> {:error, :root_symlink_redirection}
      {:error, :einval} -> :ok
      {:error, :enoent} -> {:error, :invalid_root_marker}
      {:error, _reason} -> {:error, :invalid_root}
    end
  end

  defp admit_opts(opts, allowed, defaults) do
    Enum.reduce_while(opts, {:ok, defaults, MapSet.new()}, fn
      {key, value}, {:ok, acc, seen} when is_atom(key) ->
        cond do
          not MapSet.member?(allowed, key) ->
            {:halt, {:error, {:invalid_opt, key}}}

          MapSet.member?(seen, key) ->
            {:halt, {:error, {:invalid_opt, key}}}

          true ->
            {:cont, {:ok, Map.put(acc, key, value), MapSet.put(seen, key)}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_opts}}
    end)
    |> case do
      {:ok, acc, _seen} ->
        validate_admitted(acc)

      error ->
        error
    end
  end

  defp validate_admitted(admitted) do
    json = admitted.json in [true, false]
    timeout_ok? = not Map.has_key?(admitted, :timeout_ms) || valid_timeout?(admitted.timeout_ms)

    root_ok? =
      is_nil(admitted.root) or (is_binary(admitted.root) and admitted.root != "")

    overlay_ok? = valid_overlay_expectation?(admitted)

    cond do
      not json -> {:error, {:invalid_opt, :json}}
      not timeout_ok? -> {:error, {:invalid_opt, :timeout_ms}}
      not root_ok? -> {:error, {:invalid_opt, :root}}
      not overlay_ok? -> {:error, {:invalid_opt, :overlay_size}}
      true -> {:ok, admitted}
    end
  end

  defp valid_overlay_expectation?(admitted) do
    case {Map.fetch(admitted, :overlay_size), Map.fetch(admitted, :overlay_sha256)} do
      {:error, :error} ->
        true

      {{:ok, size}, {:ok, digest}} ->
        is_integer(size) and size > 0 and is_binary(digest) and
          Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

      _other ->
        false
    end
  end

  defp valid_timeout?(timeout_ms) when is_integer(timeout_ms),
    do: timeout_ms >= 1 and timeout_ms <= @max_timeout_ms

  defp valid_timeout?(_timeout_ms), do: false
end
