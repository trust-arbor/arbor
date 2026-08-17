defmodule Arbor.Commands.SafeRecoveryClosure do
  @moduledoc """
  Imperative shell for E0B3 fresh-VM executable-closure evidence.

  Production `report/1` and `check/1` read only the committed evidence
  file. They never start a peer, inject a cookie, or compose a release.
  `measure/1` stages one trusted-build, holds `rel/arbor_trust` through
  the peer probe, then always releases the lease. `write/1` publishes
  that evidence to the single committed path. Production accepts no
  caller-selected destination, cookie, MFA, or executable.
  """

  alias Arbor.Commands.PackagingRoot
  alias Arbor.Commands.SafeRecoveryArtifact.{CheckCore, CommittedStore}
  alias Arbor.Commands.SafeRecoveryArtifact.Encode, as: ArtifactEncode

  alias Arbor.Commands.SafeRecoveryClosure.{
    Core,
    Encode,
    EvidenceStore,
    MeasureShell,
    PeerRunner
  }

  alias Arbor.Common.SafePath

  @evidence_rel "apps/arbor_commands/priv/packaging/safe_recovery_closure.v1.json"
  @max_evidence_bytes 1_048_576
  @evidence_io_timeout_ms 1_000

  @report_opt_keys MapSet.new([:json, :root])
  @measure_opt_keys MapSet.new([:json, :root, :timeout_ms])
  @test_opt_keys MapSet.union(
                   @measure_opt_keys,
                   MapSet.new([:run_peer, :evidence, :release_root, :selected])
                 )
  @default_opts %{json: false, root: nil, timeout_ms: 1_800_000}

  @doc "Fixed committed evidence path relative to the umbrella root."
  @spec default_evidence_path() :: String.t()
  def default_evidence_path, do: @evidence_rel

  @doc "Protective read ceiling for the committed evidence file."
  @spec max_evidence_bytes() :: pos_integer()
  def max_evidence_bytes, do: @max_evidence_bytes

  @spec report(keyword()) :: {:ok, map()} | {:error, term()}
  def report(opts \\ [])
  def report(opts) when is_list(opts), do: run(:report, opts, :production)
  def report(_opts), do: {:error, :invalid_opts}

  @spec check(keyword()) :: {:ok, map()} | {:error, term()}
  def check(opts \\ [])
  def check(opts) when is_list(opts), do: run(:check, opts, :production)
  def check(_opts), do: {:error, :invalid_opts}

  @spec measure(keyword()) :: {:ok, map()} | {:error, term()}
  def measure(opts \\ [])
  def measure(opts) when is_list(opts), do: run(:measure, opts, :production)
  def measure(_opts), do: {:error, :invalid_opts}

  @spec write(keyword()) :: {:ok, map()} | {:error, term()}
  def write(opts \\ [])
  def write(opts) when is_list(opts), do: run(:write, opts, :production)
  def write(_opts), do: {:error, :invalid_opts}

  @doc false
  @spec write_from_evidence_for_test(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write_from_evidence_for_test(evidence, opts)
      when is_map(evidence) and is_list(opts) do
    with {:ok, admitted} <- admit_opts(opts, @report_opt_keys),
         {:ok, root} <- resolve_root(admitted.root),
         {:ok, projected} <- Core.project(evidence),
         {:ok, bytes} <- Encode.canonical_json(projected),
         :ok <- EvidenceStore.write(root, bytes) do
      finish(:write, admitted.json, projected)
    end
  end

  def write_from_evidence_for_test(_evidence, _opts), do: {:error, :invalid_opts}

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :report)
    run(mode, Keyword.delete(opts, :mode), :test)
  end

  def run_for_test(_), do: {:error, :invalid_opts}

  defp run(mode, opts, kind) do
    allowed = if kind == :test, do: @test_opt_keys, else: allowed_keys(mode)

    with {:ok, admitted} <- admit_opts(opts, allowed),
         {:ok, root} <- resolve_root(admitted.root) do
      dispatch(mode, admitted, root, kind)
    end
  end

  defp allowed_keys(mode) when mode in [:measure, :write], do: @measure_opt_keys
  defp allowed_keys(_mode), do: @report_opt_keys

  defp dispatch(mode, admitted, root, kind) when mode in [:report, :check] do
    with {:ok, evidence} <- load_evidence(root, admitted, kind),
         {:ok, projected} <- Core.project(evidence),
         :ok <- require_check(mode, projected) do
      finish(mode, admitted.json, projected)
    end
  end

  defp dispatch(:measure, admitted, root, :production) do
    project_measurement(
      MeasureShell.measure(root: root, timeout_ms: admitted.timeout_ms),
      root,
      admitted.json
    )
  end

  defp dispatch(:write, admitted, root, :production) do
    with {:ok, result} <-
           project_measurement(
             MeasureShell.measure(root: root, timeout_ms: admitted.timeout_ms),
             root,
             admitted.json
           ),
         {:ok, bytes} <- Encode.canonical_json(result["evidence"]),
         :ok <- EvidenceStore.write(root, bytes) do
      {:ok, %{result | "mode" => "write"}}
    end
  end

  defp dispatch(:write, _admitted, _root, :test), do: {:error, :use_write_from_evidence_for_test}

  defp dispatch(:measure, admitted, root, :test) do
    cond do
      is_function(Map.get(admitted, :run_peer), 0) ->
        project_measurement(admitted.run_peer.(), root, admitted.json)

      is_binary(Map.get(admitted, :release_root)) ->
        selected = Map.get(admitted, :selected, ["e0b3_fixture"])

        project_measurement(
          PeerRunner.__test_measure__(admitted.release_root, selected),
          root,
          admitted.json
        )

      true ->
        {:error, :held_release_unavailable}
    end
  end

  defp project_measurement(result, root, json?) do
    with {:ok, measurement} <- result,
         {:ok, identity} <- load_identity(root),
         candidate <- merge_identity(identity, measurement),
         {:ok, projected} <- Core.project(candidate) do
      finish(:measure, json?, projected)
    end
  end

  defp require_check(:check, evidence) do
    with :ok <- Encode.validate_evidence(evidence),
         {:ok, again} <- Core.project(evidence),
         true <- again == evidence do
      :ok
    else
      false -> {:error, :evidence_not_canonical}
      {:error, _} = error -> error
    end
  end

  defp require_check(_mode, _evidence), do: :ok

  defp finish(mode, json?, evidence) do
    with {:ok, digest} <- Encode.evidence_digest(evidence) do
      {:ok,
       %{
         "mode" => mode_name(mode),
         "output" => if(json?, do: "json", else: "human"),
         "schema" => evidence["schema"],
         "evidence" => evidence,
         "evidence_digest" => digest,
         "closure_status" => evidence["closure_status"],
         "findings_count" => length(evidence["findings"]),
         "architecture_status" => evidence["architecture_status"]
       }}
    end
  end

  defp mode_name(:report), do: "report"
  defp mode_name(:check), do: "check"
  defp mode_name(:measure), do: "measure"
  defp mode_name(:write), do: "write"

  defp load_evidence(root, admitted, :test) do
    case Map.get(admitted, :evidence) do
      nil -> load_fixed_evidence(root)
      evidence when is_map(evidence) -> {:ok, evidence}
      _ -> {:error, :invalid_evidence}
    end
  end

  defp load_evidence(root, _admitted, :production), do: load_fixed_evidence(root)

  defp load_fixed_evidence(root) do
    with {:ok, path} <- resolve_evidence_path(root),
         {:ok, bytes} <- read_evidence_bytes(path),
         {:ok, decoded} <- decode_map(bytes) do
      {:ok, decoded}
    end
  end

  defp resolve_evidence_path(root) do
    with {:ok, lexical} <- SafePath.safe_join(root, @evidence_rel),
         :ok <- require_within(lexical, root),
         {:ok, real} <- resolve_real_or_missing(lexical),
         :ok <- require_within(real, root),
         :ok <- require_unredirected(lexical, real) do
      {:ok, lexical}
    else
      {:error, :path_traversal} -> {:error, :evidence_path_escape}
      {:error, _} = error -> error
    end
  end

  defp resolve_real_or_missing(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} -> {:ok, real}
      {:error, :not_found} -> {:error, :evidence_missing}
    end
  end

  defp require_within(path, root) do
    if SafePath.within?(path, root), do: :ok, else: {:error, :evidence_path_escape}
  end

  defp require_unredirected(path, path), do: :ok
  defp require_unredirected(_lexical, _real), do: {:error, :evidence_symlink_redirection}

  defp read_evidence_bytes(path) do
    caller = self()
    request_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {request_ref, open_evidence(path)})
      end)

    receive do
      {^request_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :evidence_reader_crashed}
    after
      @evidence_io_timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        {:error, :evidence_reader_timeout}
    end
  end

  defp open_evidence(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_evidence_bytes ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> {:error, {:evidence_unreadable, reason}}
        end

      {:ok, %{type: :regular}} ->
        {:error, :evidence_unbounded}

      {:ok, %{type: :symlink}} ->
        {:error, :evidence_symlink_redirection}

      {:ok, _} ->
        {:error, :evidence_not_regular}

      {:error, :enoent} ->
        {:error, :evidence_missing}

      {:error, reason} ->
        {:error, {:evidence_unreadable, reason}}
    end
  end

  defp decode_map(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = map} when not is_struct(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_evidence_shape}
      {:error, _} -> {:error, :invalid_evidence_json}
    end
  end

  defp load_identity(root) do
    with {:ok, %{envelope_bytes: envelope_bytes, payload_bytes: payload_bytes}} <-
           CommittedStore.read(root),
         {:ok, envelope} <- decode_map(envelope_bytes),
         {:ok, manifest} <- decode_map(payload_bytes),
         {:ok, admitted} <-
           CheckCore.admit_artifact(%{envelope_map: envelope, manifest_map: manifest}) do
      {:ok, identity_from_manifest(admitted.manifest)}
    else
      {:error, :artifact_missing} -> {:error, :artifact_missing}
      {:error, _} = error -> error
    end
  end

  defp identity_from_manifest(manifest) do
    profile = Map.fetch!(manifest, "profile")
    release = Map.fetch!(manifest, "release")

    %{
      "schema" => Core.schema(),
      "version" => 1,
      "profile" => %{
        "name" => profile["name"],
        "digest" => profile["digest"]
      },
      "artifact" => %{"payload_tree_digest" => release["payload_tree_digest"]},
      "selected_applications" =>
        ArtifactEncode.selected_first_party_names() |> MapSet.to_list() |> Enum.sort(),
      "artifact_applications" =>
        Enum.map(manifest["applications"], fn app ->
          %{"name" => app["name"], "class" => app["class"]}
        end)
    }
  end

  defp merge_identity(identity, measurement) do
    Map.merge(identity, %{
      "pre_start" => measurement["pre_start"],
      "post_start" => measurement["post_start"],
      "shutdown" => measurement["shutdown"],
      "observations" => Map.get(measurement, "observations", %{})
    })
  end

  defp resolve_root(path) do
    with {:ok, root} <- PackagingRoot.resolve(path),
         :ok <- reject_root_symlink(root),
         {:ok, real} <- SafePath.resolve_real(root) do
      {:ok, real}
    else
      {:error, :not_found} -> {:error, :invalid_root_marker}
      {:error, :umbrella_root_not_found} -> {:error, :invalid_root_marker}
      {:error, :root_symlink_redirection} = error -> error
      {:error, _} -> {:error, :invalid_root}
    end
  end

  defp reject_root_symlink(root) do
    case File.read_link(root) do
      {:ok, _} -> {:error, :root_symlink_redirection}
      {:error, :einval} -> :ok
      {:error, :enoent} -> {:error, :invalid_root_marker}
      {:error, _} -> {:error, :invalid_root}
    end
  end

  defp admit_opts(opts, allowed) do
    Enum.reduce_while(opts, {:ok, @default_opts, MapSet.new()}, fn
      {key, value}, {:ok, acc, seen} when is_atom(key) ->
        cond do
          not MapSet.member?(allowed, key) ->
            {:halt, {:error, {:production_opts_forbid_synthetic, [key]}}}

          MapSet.member?(seen, key) ->
            {:halt, {:error, {:duplicate_option, key}}}

          true ->
            case admit_value(key, value) do
              :ok ->
                {:cont, {:ok, Map.put(acc, key, value), MapSet.put(seen, key)}}

              {:error, _} = error ->
                {:halt, error}
            end
        end

      _, _ ->
        {:halt, {:error, :invalid_opts}}
    end)
    |> case do
      {:ok, admitted, _seen} -> {:ok, admitted}
      {:error, _} = error -> error
    end
  end

  defp admit_value(:json, value) when is_boolean(value), do: :ok
  defp admit_value(:root, value) when is_binary(value) or is_nil(value), do: :ok
  defp admit_value(:timeout_ms, value) when is_integer(value) and value > 0, do: :ok
  defp admit_value(:run_peer, value) when is_function(value, 0), do: :ok
  defp admit_value(:evidence, value) when is_map(value) and not is_struct(value), do: :ok
  defp admit_value(:release_root, value) when is_binary(value), do: :ok
  defp admit_value(:selected, value) when is_list(value), do: :ok
  defp admit_value(key, _value), do: {:error, {:invalid_option, key}}
end
