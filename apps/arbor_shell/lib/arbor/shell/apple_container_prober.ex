defmodule Arbor.Shell.AppleContainerProber do
  @moduledoc """
  Internal imperative Apple Container admission prober.

  Collects bounded read-only host/control-plane/image evidence, projects it
  through pure cores, and returns a normalized admitted receipt. Never wires
  `Arbor.Shell.execute_spawn_capable/3` and is not production spawn authority.

  Production entry accepts only a positive deadline duration in milliseconds
  up to 300_000. Narrow same-library test injection uses `probe_for_test/2`.
  """

  alias Arbor.Shell.AppleContainerAdmissionCore
  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.AppleContainerProbeCore
  alias Arbor.Shell.AppleContainerProbeRuntime
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.LinuxDependencyBaselineCore
  alias Arbor.Shell.TrustedPath.Identity

  @max_deadline_ms 300_000
  @global_output_budget 1_048_576

  @path_container "/usr/local/bin/container"
  @path_codesign "/usr/bin/codesign"
  @path_launchctl "/bin/launchctl"
  @path_id "/usr/bin/id"
  @path_sw_vers "/usr/bin/sw_vers"

  @fixed_executable_paths [
    @path_container,
    @path_codesign,
    @path_launchctl,
    @path_id,
    @path_sw_vers
  ]

  @cap_id 32
  @cap_sw_vers 64
  @cap_launchctl 65_536
  @cap_system_json 8_192
  @cap_image_json 262_144
  @cap_codesign 4_096

  @uid_re ~r/\A[0-9]{1,10}\z/

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

  `deadline_ms` is a positive wall-clock budget (at most 300_000) converted to
  one absolute monotonic deadline for every subprocess and non-process step.
  """
  @spec probe(term()) :: {:ok, map()} | {:error, term()}
  def probe(deadline_ms) when is_integer(deadline_ms) and deadline_ms > 0 do
    do_probe(deadline_ms, AppleContainerProbeRuntime)
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

  # --- Orchestration ---------------------------------------------------------

  defp do_probe(deadline_ms, runtime) do
    try do
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
  end

  defp probe_pipeline(deadline_ms, runtime) do
    with {:ok, budget_ms} <- validate_deadline(deadline_ms),
         state <- new_state(runtime, budget_ms),
         {:ok, state} <- resolve_all_executables(state),
         {:ok, bindings} <- checkout_bindings(state),
         :ok <- match_cli_executable(state, bindings),
         {:ok, policy} <- checkout_policy(state),
         {:ok, receipt} <- checkout_and_normalize_receipt(state),
         {:ok, refs} <- AppleContainerAdmissionCore.execution_references(policy),
         workload_alias <- refs.image.execution_reference,
         vminit_alias <- refs.vminit.execution_reference,
         # All three codesign verifications before any /usr/local/bin/container run.
         {:ok, state, cli_signing} <- run_codesign(state, :cli, bindings),
         {:ok, state, api_signing} <- run_codesign(state, :apiserver, bindings),
         {:ok, state, plugin_signing} <- run_codesign(state, :plugin, bindings),
         {:ok, state, uid_raw} <- run_id(state),
         {:ok, uid} <- parse_uid_for_launchctl(uid_raw),
         {:ok, state, sw_vers} <- run_sw_vers(state),
         {:ok, state, launchctl} <- run_launchctl(state, uid),
         {:ok, state, version_json} <- run_system_version(state),
         {:ok, state, status_json} <- run_system_status(state),
         {:ok, state, workload_json} <- run_image_inspect(state, workload_alias),
         {:ok, state, vminit_json} <- run_image_inspect(state, vminit_alias),
         :ok <- ensure_deadline(state),
         {:ok, plugin_toml} <- read_plugin_config(state, bindings),
         :ok <- ensure_deadline(state),
         :ok <- prove_user_plugin_absent(state),
         :ok <- ensure_deadline(state),
         {:ok, arch} <- system_architecture(state),
         {:ok, projection} <-
           project_probe(%{
             system_architecture: arch,
             sw_vers_output: sw_vers,
             uid_output: uid_raw,
             launchctl_output: launchctl,
             system_version_json: version_json,
             system_status_json: status_json,
             workload_image_inspect_json: workload_json,
             vminit_image_inspect_json: vminit_json,
             runtime_plugin_config_toml: plugin_toml
           }),
         {:ok, admission_input} <-
           assemble_admission_input(
             projection,
             bindings,
             receipt,
             cli_signing,
             api_signing,
             plugin_signing,
             policy
           ),
         {:ok, admitted} <- AppleContainerAdmissionCore.new(admission_input, bindings),
         :ok <- revalidate_end(state, bindings, policy, receipt),
         :ok <- ensure_deadline(state) do
      {:ok, AppleContainerAdmissionCore.show(admitted)}
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

  # --- Resolves --------------------------------------------------------------

  defp resolve_all_executables(state) do
    Enum.reduce_while(
      @fixed_executable_paths,
      {:ok, state},
      fn path, {:ok, acc} ->
        case acc.runtime.resolve_executable(path) do
          {:ok, %Executable{} = executable} ->
            {:cont,
             {:ok,
              %{
                acc
                | resolves: Map.put(acc.resolves, path, executable),
                  resolve_order: acc.resolve_order ++ [path]
              }}}

          {:error, reason} ->
            {:halt, {:error, bound_reason(reason, :executable_resolve_failed)}}
        end
      end
    )
  end

  defp match_cli_executable(state, bindings) do
    with %Executable{} = exe <- Map.get(state.resolves, @path_container),
         %Identity{} = identity <- Map.get(bindings, :cli_identity) do
      if executable_matches_identity?(exe, identity) do
        :ok
      else
        {:error, :cli_executable_identity_mismatch}
      end
    else
      _ -> {:error, :cli_executable_identity_mismatch}
    end
  end

  defp executable_matches_identity?(%Executable{} = exe, %Identity{} = identity) do
    exe.path == identity.path and
      exe.device == identity.device and
      exe.inode == identity.inode and
      exe.size == identity.size and
      exe.mtime == identity.mtime and
      exe.ctime == identity.ctime and
      exe.mode == identity.mode and
      exe.sha256 == identity.sha256
  end

  # --- Authority checkout ----------------------------------------------------

  defp checkout_bindings(state) do
    case state.runtime.checkout_control_plane_bindings() do
      {:ok, bindings} when is_map(bindings) -> {:ok, bindings}
      {:error, reason} -> {:error, bound_reason(reason, :control_plane_unavailable)}
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
         :ok <- validate_plan_keys(plan),
         {:ok, receipt} <-
           LinuxDependencyBaselineCore.normalize_compact_receipt(plan["receipt"]) do
      {:ok, receipt}
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

  # --- Commands --------------------------------------------------------------

  defp run_id(state) do
    with {:ok, state, out} <- run_cmd(state, @path_id, ["-u"], @cap_id) do
      {:ok, state, out}
    end
  end

  defp run_sw_vers(state) do
    with {:ok, state, out} <- run_cmd(state, @path_sw_vers, ["-productVersion"], @cap_sw_vers) do
      {:ok, state, out}
    end
  end

  defp run_launchctl(state, uid) when is_binary(uid) do
    service = "gui/#{uid}/com.apple.container.apiserver"

    with {:ok, state, out} <-
           run_cmd(state, @path_launchctl, ["print", service], @cap_launchctl) do
      {:ok, state, out}
    end
  end

  defp parse_uid_for_launchctl(raw) when is_binary(raw) do
    uid = String.trim(raw)

    if Regex.match?(@uid_re, uid) do
      {:ok, uid}
    else
      {:error, :invalid_uid_output}
    end
  end

  defp parse_uid_for_launchctl(_raw), do: {:error, :invalid_uid_output}

  defp run_system_version(state) do
    with {:ok, state, out} <-
           run_cmd(
             state,
             @path_container,
             ["system", "version", "--format", "json"],
             @cap_system_json
           ) do
      {:ok, state, out}
    end
  end

  defp run_system_status(state) do
    with {:ok, state, out} <-
           run_cmd(
             state,
             @path_container,
             ["system", "status", "--format", "json"],
             @cap_system_json
           ) do
      {:ok, state, out}
    end
  end

  defp run_image_inspect(state, reference) when is_binary(reference) do
    with {:ok, state, out} <-
           run_cmd(
             state,
             @path_container,
             ["image", "inspect", reference],
             @cap_image_json
           ) do
      {:ok, state, out}
    end
  end

  defp run_codesign(state, role, bindings) do
    with {:ok, path, requirement, identifier} <- role_codesign_target(role, bindings),
         argv = ["--verify", "--strict", "--all-architectures", "-R=#{requirement}", path],
         {:ok, state, _out} <- run_cmd(state, @path_codesign, argv, @cap_codesign) do
      signing = %{
        identifier: identifier,
        team_id: ControlPlane.team_id(),
        designated_requirement: requirement,
        verified_against: requirement,
        status: "valid"
      }

      {:ok, state, signing}
    else
      {:error, {:role_path_mismatch, _} = reason} ->
        {:error, reason}

      {:error, :role_identity_missing} = err ->
        err

      {:error, :deadline_exhausted} = err ->
        err

      {:error, :output_budget_exhausted} = err ->
        err

      {:error, :executable_not_resolved} = err ->
        err

      {:error, _reason} ->
        {:error, {:codesign_failed, role}}
    end
  end

  defp role_codesign_target(:cli, bindings) do
    role_path_and_requirement(
      bindings,
      :cli_identity,
      ControlPlane.cli_path(),
      ControlPlane.cli_designated_requirement(),
      ControlPlane.cli_identifier(),
      :cli
    )
  end

  defp role_codesign_target(:apiserver, bindings) do
    role_path_and_requirement(
      bindings,
      :apiserver_identity,
      ControlPlane.apiserver_path(),
      ControlPlane.apiserver_designated_requirement(),
      ControlPlane.apiserver_identifier(),
      :apiserver
    )
  end

  defp role_codesign_target(:plugin, bindings) do
    role_path_and_requirement(
      bindings,
      :runtime_plugin_identity,
      ControlPlane.plugin_path(),
      ControlPlane.plugin_designated_requirement(),
      ControlPlane.plugin_identifier(),
      :plugin
    )
  end

  defp role_path_and_requirement(
         bindings,
         identity_key,
         fixed_path,
         requirement,
         identifier,
         role
       ) do
    case Map.get(bindings, identity_key) do
      %Identity{path: path} when path == fixed_path ->
        {:ok, fixed_path, requirement, identifier}

      %Identity{} ->
        {:error, {:role_path_mismatch, role}}

      _other ->
        {:error, :role_identity_missing}
    end
  end

  defp run_cmd(state, path, args, cap) do
    case ensure_deadline(state) do
      :ok ->
        case Map.fetch(state.resolves, path) do
          {:ok, %Executable{} = executable} ->
            remaining_ms = remaining_timeout(state)
            remaining_out = state.remaining_output

            cond do
              remaining_ms <= 0 ->
                {:error, :deadline_exhausted}

              remaining_out <= 0 ->
                {:error, :output_budget_exhausted}

              true ->
                max_out = min(cap, remaining_out)

                opts = [
                  cwd: "/",
                  clear_env: true,
                  timeout: remaining_ms,
                  max_output_bytes: max_out
                ]

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

          :error ->
            {:error, :executable_not_resolved}
        end

      {:error, _} = err ->
        err
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

  # --- File / host evidence --------------------------------------------------

  defp read_plugin_config(state, bindings) do
    identity = Map.get(bindings, :runtime_plugin_config_identity)

    case state.runtime.read_plugin_config(identity) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, reason} -> {:error, bound_reason(reason, :plugin_config_read_failed)}
    end
  end

  defp prove_user_plugin_absent(state) do
    case state.runtime.prove_user_plugin_root_absent() do
      :ok -> :ok
      {:error, reason} -> {:error, bound_reason(reason, :user_plugin_root_not_absent)}
    end
  end

  defp system_architecture(state) do
    case state.runtime.system_architecture() do
      arch when is_list(arch) -> {:ok, List.to_string(arch)}
      arch when is_binary(arch) -> {:ok, arch}
      _other -> {:error, :invalid_system_architecture}
    end
  end

  defp project_probe(raw) do
    case AppleContainerProbeCore.project(raw) do
      {:ok, projection} -> {:ok, projection}
      {:error, reason} -> {:error, bound_reason(reason, :probe_projection_failed)}
    end
  end

  # --- Admission assembly ----------------------------------------------------

  defp assemble_admission_input(
         projection,
         bindings,
         baseline_receipt,
         cli_signing,
         api_signing,
         plugin_signing,
         policy
       ) do
    control_plane = %{
      cli: %{
        identity: bindings.cli_identity,
        version: projection.control_plane.cli.version,
        build: projection.control_plane.cli.build,
        signing: cli_signing
      },
      apiserver: %{
        identity: bindings.apiserver_identity,
        version: projection.control_plane.apiserver.version,
        build: projection.control_plane.apiserver.build,
        signing: api_signing,
        launchd: projection.control_plane.apiserver.launchd
      },
      service_status: projection.control_plane.service_status,
      runtime_plugin: %{
        identity: bindings.runtime_plugin_identity,
        config_identity: bindings.runtime_plugin_config_identity,
        signing: plugin_signing,
        config: projection.control_plane.runtime_plugin.config
      },
      user_plugin_root: %{
        path: ControlPlane.user_plugin_root_path(),
        status: "absent"
      },
      kernel_identity: bindings.kernel_identity
    }

    evidence = %{
      host_platform: projection.host_platform,
      runtime: %{
        path: ControlPlane.cli_path(),
        cli_version: projection.runtime.cli_version,
        cli_build: projection.runtime.cli_build,
        executable_sha256: bindings.cli_identity.sha256,
        signing: cli_signing
      },
      service_status: projection.service_status,
      image_inspect: projection.image_inspect,
      vminit_image_inspect: projection.vminit_image_inspect,
      dependency_baseline: baseline_receipt,
      control_plane: control_plane
    }

    {:ok, %{policy: policy, evidence: evidence}}
  end

  defp revalidate_end(state, bindings, policy, receipt) do
    with :ok <- ensure_deadline(state),
         {:ok, bindings2} <- checkout_bindings(state),
         :ok <- require_unchanged(bindings2, bindings, :control_plane_bindings_drift),
         :ok <- ensure_deadline(state),
         {:ok, policy2} <- checkout_policy(state),
         :ok <- require_unchanged(policy2, policy, :image_policy_drift),
         :ok <- ensure_deadline(state),
         {:ok, receipt2} <- checkout_and_normalize_receipt(state),
         :ok <- require_unchanged(receipt2, receipt, :baseline_receipt_drift),
         :ok <- ensure_deadline(state),
         :ok <- verify_all_executables(state),
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

  defp verify_all_executables(state) do
    Enum.reduce_while(@fixed_executable_paths, :ok, fn path, :ok ->
      case Map.fetch(state.resolves, path) do
        {:ok, %Executable{} = executable} ->
          case state.runtime.verify_executable(executable) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, bound_reason(reason, :executable_drift)}}
          end

        :error ->
          {:halt, {:error, :executable_not_resolved}}
      end
    end)
  end

  # --- Options / errors ------------------------------------------------------

  defp normalize_test_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Enum.reduce_while(opts, {:ok, AppleContainerProbeRuntime, MapSet.new()}, fn
        {key, value}, {:ok, _runtime, seen} ->
          if MapSet.member?(@allowed_test_keys, key) do
            if MapSet.member?(seen, key) do
              {:halt, {:error, :duplicate_probe_test_option}}
            else
              case key do
                :runtime when is_atom(value) ->
                  {:cont, {:ok, value, MapSet.put(seen, key)}}

                :runtime ->
                  {:halt, {:error, :invalid_probe_runtime}}
              end
            end
          else
            {:halt, {:error, :unknown_probe_test_option}}
          end

        _other, _acc ->
          {:halt, {:error, :malformed_probe_test_options}}
      end)
      |> case do
        {:ok, runtime, _seen} -> {:ok, runtime}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :malformed_probe_test_options}
    end
  end

  defp normalize_test_opts(_opts), do: {:error, :malformed_probe_test_options}

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
