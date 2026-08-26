defmodule Arbor.Shell.OciProber do
  @moduledoc """
  Internal imperative OCI/Podman admission prober.

  Resolves `/usr/bin/podman`, checks out baseline + image policy, inspects a
  digest-only image, and returns a JSON-clean admitted receipt for
  `OciExecutionCore`. Invoked by `OciExecutor`; this module is not a public
  facade.

  Production entry accepts only a positive deadline duration in milliseconds
  up to 300_000. Narrow same-library test injection uses `probe_for_test/2`.
  """

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.LinuxDependencyBaselineCore
  alias Arbor.Shell.OciAdmissionCore
  alias Arbor.Shell.OciHostEnv
  alias Arbor.Shell.OciHostEnvCore
  alias Arbor.Shell.OciProbeCore
  alias Arbor.Shell.OciProbeRuntime
  alias Arbor.Shell.SpawnCapableTimeout

  @max_deadline_ms SpawnCapableTimeout.max_probe_deadline_ms()
  @global_output_budget 1_048_576
  @path_podman "/usr/bin/podman"
  @cap_image_json 262_144
  @sha256_digest_re ~r/\Asha256:[0-9a-f]{64}\z/
  @hex64_re ~r/\A[0-9a-f]{64}\z/

  @allowed_test_keys MapSet.new([:runtime])

  @type probe_state :: %{
          runtime: module(),
          deadline_mono: integer(),
          remaining_output: non_neg_integer(),
          resolves: %{optional(String.t()) => Executable.t()},
          resolve_order: [String.t()],
          runs: [map()]
        }

  @doc """
  Probe and admit using production authorities and process runtime.
  """
  @spec probe(term()) :: {:ok, map()} | {:error, term()}
  def probe(deadline_ms) when is_integer(deadline_ms) and deadline_ms > 0 do
    do_probe(deadline_ms, OciProbeRuntime)
  end

  def probe(_deadline_ms), do: {:error, :invalid_probe_deadline}

  @doc false
  @spec probe_for_test(term(), term()) :: {:ok, map()} | {:error, term()}
  def probe_for_test(deadline_ms, opts) when is_integer(deadline_ms) and deadline_ms > 0 do
    with {:ok, runtime} <- normalize_test_opts(opts) do
      do_probe(deadline_ms, runtime)
    end
  end

  def probe_for_test(_deadline_ms, _opts), do: {:error, :invalid_probe_deadline}

  defp do_probe(deadline_ms, runtime) do
    probe_pipeline(deadline_ms, runtime)
  rescue
    _exception ->
      {:error, :probe_failed}
  catch
    :throw, _value ->
      {:error, :probe_failed}

    :exit, _reason ->
      {:error, :probe_failed}
  end

  defp probe_pipeline(deadline_ms, runtime) do
    with {:ok, budget_ms} <- validate_deadline(deadline_ms),
         state <- new_state(runtime, budget_ms),
         {:ok, state} <- resolve_runtime(state),
         {:ok, policy} <- checkout_policy(state),
         {:ok, receipt} <- checkout_and_normalize_receipt(state),
         {:ok, arch} <- system_architecture(state),
         {:ok, digest} <- fetch_execution_digest(state, policy),
         {:ok, state, inspect_json} <- run_image_inspect(state, digest),
         :ok <- ensure_deadline(state),
         {:ok, projection} <-
           project_probe(%{system_architecture: arch, image_inspect_json: inspect_json}),
         {:ok, oci_policy} <- assemble_oci_policy(policy, receipt, projection),
         {:ok, admitted} <-
           OciAdmissionCore.new(%{policy: oci_policy, evidence: %{inspect: projection.inspect}}),
         :ok <- revalidate_end(state, policy, receipt),
         :ok <- ensure_deadline(state) do
      {:ok, show_admission(admitted, projection)}
    end
  end

  defp new_state(runtime, budget_ms) do
    now = runtime.monotonic_ms()

    %{
      runtime: runtime,
      deadline_mono: now + budget_ms,
      remaining_output: @global_output_budget,
      resolves: %{},
      resolve_order: [],
      runs: []
    }
  end

  defp validate_deadline(deadline_ms)
       when is_integer(deadline_ms) and deadline_ms > 0 and deadline_ms <= @max_deadline_ms do
    {:ok, deadline_ms}
  end

  defp validate_deadline(_deadline_ms), do: {:error, :invalid_probe_deadline}

  defp resolve_runtime(state) do
    case state.runtime.resolve_executable(@path_podman) do
      {:ok, %Executable{path: @path_podman} = executable} ->
        {:ok,
         %{
           state
           | resolves: Map.put(state.resolves, @path_podman, executable),
             resolve_order: state.resolve_order ++ [@path_podman]
         }}

      {:ok, %Executable{}} ->
        {:error, :untrusted_path}

      {:error, reason} ->
        {:error, bound_reason(reason, :runtime_executable_unavailable)}
    end
  end

  defp checkout_policy(state) do
    case state.runtime.checkout_image_policy() do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      {:error, reason} -> {:error, bound_reason(reason, :image_policy_unavailable)}
    end
  end

  defp checkout_and_normalize_receipt(state) do
    with {:ok, plan} <- checkout_plan(state),
         :ok <- validate_plan_keys(plan) do
      LinuxDependencyBaselineCore.normalize_compact_receipt(plan["receipt"])
    end
  end

  defp checkout_plan(state) do
    case state.runtime.checkout_baseline_plan() do
      {:ok, plan} when is_map(plan) -> {:ok, plan}
      {:error, reason} -> {:error, bound_reason(reason, :baseline_unavailable)}
    end
  end

  defp validate_plan_keys(plan) when is_map(plan) do
    if is_map(plan["receipt"]) do
      :ok
    else
      {:error, :invalid_baseline_plan}
    end
  end

  defp fetch_execution_digest(state, policy) do
    runtime = state.runtime

    result =
      if function_exported?(runtime, :execution_digest, 1) do
        runtime.execution_digest(policy)
      else
        OciProbeRuntime.execution_digest(policy)
      end

    case result do
      {:ok, digest} when is_binary(digest) ->
        if Regex.match?(@sha256_digest_re, digest) do
          {:ok, digest}
        else
          {:error, :not_digest_execution_image}
        end

      {:error, reason} ->
        {:error, bound_reason(reason, :not_digest_execution_image)}

      _other ->
        {:error, :not_digest_execution_image}
    end
  end

  defp run_image_inspect(state, digest) when is_binary(digest) do
    run_cmd(state, @path_podman, ["image", "inspect", digest], @cap_image_json)
  end

  defp run_cmd(state, path, args, cap) do
    with :ok <- ensure_deadline(state),
         {:ok, executable} <- fetch_resolved(state, path) do
      dispatch_run(state, executable, path, args, cap)
    end
  end

  defp fetch_resolved(state, path) do
    case Map.fetch(state.resolves, path) do
      {:ok, %Executable{} = executable} -> {:ok, executable}
      :error -> {:error, :executable_not_resolved}
    end
  end

  defp dispatch_run(state, executable, path, args, cap) do
    remaining_ms = remaining_timeout(state)
    remaining_out = state.remaining_output

    cond do
      remaining_ms <= 0 ->
        {:error, :deadline_exhausted}

      remaining_out <= 0 ->
        {:error, :output_budget_exhausted}

      true ->
        with {:ok, host_env} <- fetch_host_env(state) do
          opts = [
            cwd: "/",
            clear_env: true,
            env: host_env,
            timeout: remaining_ms,
            max_output_bytes: min(cap, remaining_out)
          ]

          invoke_run_bound(state, executable, path, args, opts)
        end
    end
  end

  defp fetch_host_env(state) do
    result =
      if function_exported?(state.runtime, :rootless_host_env, 0) do
        state.runtime.rootless_host_env()
      else
        OciHostEnv.resolve()
      end

    case result do
      {:ok, env} ->
        case OciHostEnvCore.require_closed(env) do
          :ok -> {:ok, env}
          error -> error
        end

      {:error, reason} ->
        {:error, bound_reason(reason, :rootless_host_env_unavailable)}

      _other ->
        {:error, :rootless_host_env_unavailable}
    end
  end

  defp invoke_run_bound(state, executable, path, args, opts) do
    case state.runtime.run_bound(executable, args, opts) do
      {:ok, result} ->
        with :ok <- interpret_result(result),
             {:ok, state} <- debit_output(state, result, path, args, opts) do
          {:ok, state, Map.get(result, :stdout, "")}
        end

      {:error, reason} ->
        {:error, bound_reason(reason, :probe_command_failed)}
    end
  end

  defp interpret_result(%{exit_code: 0, timed_out: false} = result) do
    cond do
      Map.get(result, :cancelled) == true ->
        {:error, :probe_cancelled}

      Map.get(result, :containment_failure) == true ->
        {:error, :probe_containment_failure}

      Map.get(result, :output_limit_exceeded) == true or
          Map.get(result, :output_truncated) == true ->
        {:error, :probe_output_limit}

      true ->
        :ok
    end
  end

  defp interpret_result(%{timed_out: true}), do: {:error, :probe_timeout}

  defp interpret_result(%{exit_code: code}) when is_integer(code) and code != 0,
    do: {:error, :probe_nonzero_exit}

  defp interpret_result(_), do: {:error, :probe_command_failed}

  defp debit_output(state, result, path, args, opts) do
    out = Map.get(result, :stdout, "")
    used = byte_size(out)

    if used > state.remaining_output do
      {:error, :output_budget_exhausted}
    else
      run = %{path: path, args: args, opts: opts, bytes: used}

      {:ok,
       %{
         state
         | remaining_output: state.remaining_output - used,
           runs: state.runs ++ [run]
       }}
    end
  end

  defp ensure_deadline(state) do
    if remaining_timeout(state) > 0, do: :ok, else: {:error, :deadline_exhausted}
  end

  defp remaining_timeout(state) do
    state.deadline_mono - state.runtime.monotonic_ms()
  end

  defp system_architecture(state) do
    case state.runtime.system_architecture() do
      arch when is_list(arch) -> {:ok, List.to_string(arch)}
      arch when is_binary(arch) -> {:ok, arch}
      _other -> {:error, :invalid_system_architecture}
    end
  end

  defp project_probe(raw) do
    case OciProbeCore.project(raw) do
      {:ok, projection} -> {:ok, projection}
      {:error, reason} -> {:error, bound_reason(reason, :probe_projection_failed)}
    end
  end

  defp assemble_oci_policy(policy, receipt, projection) do
    with {:ok, image} <- fetch_policy_image(policy),
         {:ok, labels} <- fetch_policy_labels(policy),
         {:ok, toolchain} <- fetch_policy_toolchain(policy),
         {:ok, mix_lock} <-
           require_matching_hex64(
             policy_hex64(policy, :mix_lock_digest),
             receipt["mix_lock_digest"],
             :missing_mix_lock_digest,
             :baseline_mix_lock_digest_mismatch
           ),
         {:ok, tree} <-
           require_matching_hex64(
             policy_hex64(policy, :baseline_tree_digest),
             receipt["baseline_tree_digest"],
             :missing_baseline_tree_digest,
             :baseline_tree_digest_mismatch
           ),
         :ok <- require_guest_platform(projection) do
      policy_map = %{
        image: image,
        manifest_digest: policy_manifest_digest(policy, projection),
        labels: labels,
        mix_lock_digest: mix_lock,
        baseline_tree_digest: tree,
        toolchain: toolchain,
        platform: projection.guest_platform
      }

      {:ok, maybe_put_image_id(policy_map, policy)}
    end
  end

  defp maybe_put_image_id(policy_map, policy) do
    case get_field(policy, :image_id) do
      id when is_binary(id) and id != "" -> Map.put(policy_map, :image_id, id)
      _other -> policy_map
    end
  end

  defp fetch_policy_image(policy) do
    case get_field(policy, :image) do
      image when is_binary(image) and image != "" -> {:ok, image}
      nil -> {:error, :missing_policy_image}
      _other -> {:error, :invalid_policy_image}
    end
  end

  defp fetch_policy_labels(policy) do
    case get_field(policy, :labels) do
      labels when is_map(labels) -> {:ok, stringify_keys(labels)}
      nil -> {:error, :missing_labels}
      _other -> {:error, :invalid_labels}
    end
  end

  defp fetch_policy_toolchain(policy) do
    case get_field(policy, :toolchain) do
      toolchain when is_map(toolchain) ->
        erlang = get_field(toolchain, :erlang)
        elixir = get_field(toolchain, :elixir)

        if is_binary(erlang) and erlang != "" and is_binary(elixir) and elixir != "" do
          {:ok, %{erlang: erlang, elixir: elixir}}
        else
          {:error, :missing_toolchain}
        end

      nil ->
        {:error, :missing_toolchain}

      _other ->
        {:error, :invalid_toolchain}
    end
  end

  defp policy_hex64(policy, key) do
    case get_field(policy, key) do
      value when is_binary(value) -> strip_sha256_prefix(value)
      _other -> nil
    end
  end

  defp strip_sha256_prefix("sha256:" <> hex), do: hex
  defp strip_sha256_prefix(value), do: value

  defp require_matching_hex64(policy_value, receipt_value, missing, mismatch) do
    receipt_hex = strip_sha256_prefix(receipt_value)

    cond do
      not is_binary(policy_value) and not is_binary(receipt_hex) ->
        {:error, missing}

      is_binary(policy_value) and not Regex.match?(@hex64_re, policy_value) ->
        {:error, :invalid_hex64}

      is_binary(receipt_hex) and not Regex.match?(@hex64_re, receipt_hex) ->
        {:error, :invalid_hex64}

      is_binary(policy_value) and is_binary(receipt_hex) and policy_value != receipt_hex ->
        {:error, mismatch}

      is_binary(policy_value) ->
        {:ok, policy_value}

      is_binary(receipt_hex) ->
        {:ok, receipt_hex}

      true ->
        {:error, missing}
    end
  end

  defp require_guest_platform(%{guest_platform: platform})
       when platform in ["linux/amd64", "linux/arm64"],
       do: :ok

  defp require_guest_platform(_), do: {:error, :unsupported_platform}

  defp policy_manifest_digest(policy, projection) do
    case get_field(policy, :manifest_digest) do
      digest when is_binary(digest) and digest != "" -> digest
      _other -> Map.fetch!(projection.inspect, "Digest")
    end
  end

  defp show_admission(admitted, projection) when is_map(admitted) do
    %{
      "admitted" => true,
      "platform" => %{
        "os" => projection.host_platform.os,
        "architecture" => projection.host_platform.architecture
      },
      "runtime" => %{"path" => @path_podman},
      "image" => %{
        "execution_reference" => admitted["execution_image"],
        "platform" => admitted["platform"]
      }
    }
  end

  defp revalidate_end(state, policy, receipt) do
    with :ok <- ensure_deadline(state),
         {:ok, policy2} <- checkout_policy(state),
         :ok <- require_unchanged(policy2, policy, :image_policy_drift),
         :ok <- ensure_deadline(state),
         {:ok, receipt2} <- checkout_and_normalize_receipt(state),
         :ok <- require_unchanged(receipt2, receipt, :baseline_receipt_drift),
         :ok <- ensure_deadline(state),
         :ok <- verify_runtime(state),
         :ok <- ensure_deadline(state) do
      :ok
    else
      {:error, reason} ->
        {:error, bound_reason(reason, :authority_drift)}
    end
  end

  defp require_unchanged(left, right, drift_reason) do
    if left === right do
      :ok
    else
      {:error, drift_reason}
    end
  end

  defp verify_runtime(state) do
    case Map.fetch(state.resolves, @path_podman) do
      {:ok, %Executable{} = executable} ->
        case state.runtime.verify_executable(executable) do
          :ok -> :ok
          {:error, reason} -> {:error, bound_reason(reason, :executable_drift)}
        end

      :error ->
        {:error, :executable_not_resolved}
    end
  end

  defp normalize_test_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      finish_test_opts(
        Enum.reduce_while(opts, {:ok, OciProbeRuntime, MapSet.new()}, &accumulate_test_opt/2)
      )
    else
      {:error, :malformed_probe_test_options}
    end
  end

  defp normalize_test_opts(_opts), do: {:error, :malformed_probe_test_options}

  defp accumulate_test_opt({key, value}, {:ok, _runtime, seen}) do
    cond do
      not MapSet.member?(@allowed_test_keys, key) ->
        {:halt, {:error, :unknown_probe_test_option}}

      MapSet.member?(seen, key) ->
        {:halt, {:error, :duplicate_probe_test_option}}

      key == :runtime and is_atom(value) ->
        {:cont, {:ok, value, MapSet.put(seen, key)}}

      key == :runtime ->
        {:halt, {:error, :invalid_probe_runtime}}

      true ->
        {:halt, {:error, :unknown_probe_test_option}}
    end
  end

  defp accumulate_test_opt(_other, _acc), do: {:halt, {:error, :malformed_probe_test_options}}

  defp finish_test_opts({:ok, runtime, _seen}), do: {:ok, runtime}
  defp finish_test_opts({:error, reason}), do: {:error, reason}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {inspect(key), value}
    end)
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp bound_reason(reason, _fallback) when is_atom(reason), do: reason

  defp bound_reason(reason, _fallback) when is_tuple(reason) do
    components = Tuple.to_list(reason)

    if components != [] and Enum.all?(components, &is_atom/1) do
      reason
    else
      :probe_failed
    end
  end

  defp bound_reason(_reason, fallback) when is_atom(fallback), do: fallback
end
