defmodule Arbor.Shell.AppleContainerProbeRuntime do
  @moduledoc """
  Production runtime adapter for Apple Container admission probing.

  Isolates process execution, authority checkout, and bounded file IO so
  `AppleContainerProber` can be exercised with a same-library test double.
  This module is not executable spawn authority.
  """

  alias Arbor.Shell.AppleContainerAdmissionCore
  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.AppleContainerControlPlaneAuthority
  alias Arbor.Shell.AppleContainerImagePolicyAuthority
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.Executor
  alias Arbor.Shell.LinuxDependencyBaselineAuthority
  alias Arbor.Shell.SpawnCapableTimeout
  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @max_plugin_config_bytes 8_192
  @max_probe_deadline_ms SpawnCapableTimeout.max_probe_deadline_ms()
  @max_system_json_bytes 8_192
  @max_image_json_bytes 262_144

  @container_path "/usr/local/bin/container"
  @container_probe_option_keys [:clear_env, :cwd, :max_output_bytes, :timeout]

  @callback monotonic_ms() :: integer()
  @callback system_architecture() :: charlist() | binary()
  @callback resolve_executable(String.t()) :: {:ok, Executable.t()} | {:error, term()}
  @callback verify_executable(Executable.t()) :: :ok | {:error, term()}
  @callback run_bound(Executable.t(), [String.t()], keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback checkout_control_plane_bindings() :: {:ok, map()} | {:error, term()}
  @callback checkout_image_policy() :: {:ok, map()} | {:error, term()}
  @callback checkout_baseline_plan() :: {:ok, map()} | {:error, term()}
  @callback verify_identity(Identity.t()) :: :ok | {:error, term()}
  @callback read_plugin_config(Identity.t()) :: {:ok, binary()} | {:error, term()}
  @callback prove_user_plugin_root_absent() :: :ok | {:error, term()}

  @doc false
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc false
  @spec system_architecture() :: charlist() | binary()
  def system_architecture, do: :erlang.system_info(:system_architecture)

  @doc false
  @spec resolve_executable(String.t()) :: {:ok, Executable.t()} | {:error, term()}
  def resolve_executable(path) when is_binary(path) do
    case ExecutablePolicy.resolve(path) do
      {:ok, %Executable{} = executable} -> {:ok, executable}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  def resolve_executable(_path), do: {:error, :executable_not_found}

  @doc false
  @spec verify_executable(Executable.t()) :: :ok | {:error, term()}
  def verify_executable(%Executable{} = executable) do
    case ExecutablePolicy.verify_pinned(executable) do
      :ok -> :ok
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  def verify_executable(_), do: {:error, :executable_not_pinned}

  @doc false
  @spec run_bound(Executable.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run_bound(%Executable{} = executable, args, opts)
      when is_list(args) and is_list(opts) do
    runner =
      if executable.path == @container_path do
        &run_apple_container_probe/3
      else
        &Executor.run_bound/3
      end

    case runner.(executable, args, opts) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  def run_bound(_executable, _args, _opts), do: {:error, :invalid_run_bound}

  @doc false
  @spec authorize_container_probe_args(term(), term()) :: :ok | {:error, term()}
  def authorize_container_probe_args(["system", operation, "--format", "json"], _policy)
      when operation in ["version", "status"],
      do: :ok

  def authorize_container_probe_args(["image", "inspect", reference], policy)
      when is_binary(reference) and is_map(policy) do
    with {:ok, refs} <- AppleContainerAdmissionCore.execution_references(policy),
         true <-
           reference in [refs.image.execution_reference, refs.vminit.execution_reference] do
      :ok
    else
      _ -> {:error, :unreviewed_apple_container_probe_command}
    end
  end

  def authorize_container_probe_args(_args, _policy),
    do: {:error, :unreviewed_apple_container_probe_command}

  defp run_apple_container_probe(%Executable{} = executable, args, opts) do
    started_at = monotonic_ms()

    with {:ok, max_output_bytes} <- reviewed_container_probe(args),
         :ok <- validate_container_probe_opts(opts, max_output_bytes),
         :ok <- require_authority_cli_identity(executable),
         :ok <- require_policy_alias(args),
         {:ok, execution_opts} <- debit_probe_timeout(opts, started_at) do
      Executor.run_apple_container_probe(executable, args, execution_opts)
    end
  end

  defp reviewed_container_probe(["system", operation, "--format", "json"])
       when operation in ["version", "status"],
       do: {:ok, @max_system_json_bytes}

  defp reviewed_container_probe(["image", "inspect", reference]) when is_binary(reference),
    do: {:ok, @max_image_json_bytes}

  defp reviewed_container_probe(_args), do: {:error, :unreviewed_apple_container_probe_command}

  defp validate_container_probe_opts(opts, max_output_bytes) do
    if Keyword.keyword?(opts) do
      keys = opts |> Keyword.keys() |> Enum.sort()
      timeout = Keyword.get(opts, :timeout)
      output_bytes = Keyword.get(opts, :max_output_bytes)

      if keys == @container_probe_option_keys and Keyword.get(opts, :cwd) == "/" and
           Keyword.get(opts, :clear_env) == true and is_integer(timeout) and timeout > 0 and
           timeout <= @max_probe_deadline_ms and is_integer(output_bytes) and output_bytes > 0 and
           output_bytes <= max_output_bytes do
        :ok
      else
        {:error, :invalid_apple_container_probe_options}
      end
    else
      {:error, :invalid_apple_container_probe_options}
    end
  end

  defp debit_probe_timeout(opts, started_at) do
    remaining = Keyword.fetch!(opts, :timeout) - max(monotonic_ms() - started_at, 0)

    if remaining > 0 do
      {:ok, Keyword.put(opts, :timeout, remaining)}
    else
      {:error, :deadline_exhausted}
    end
  end

  defp require_authority_cli_identity(%Executable{} = executable) do
    with {:ok, bindings} <- checkout_control_plane_bindings(),
         %Identity{} = identity <- Map.get(bindings, :cli_identity),
         true <- executable_matches_identity?(executable, identity) do
      :ok
    else
      _ -> {:error, :apple_container_probe_identity_mismatch}
    end
  end

  defp require_policy_alias(["image", "inspect", reference]) do
    with {:ok, policy} <- checkout_image_policy(),
         :ok <- authorize_container_probe_args(["image", "inspect", reference], policy) do
      :ok
    end
  end

  defp require_policy_alias(["system", operation, "--format", "json"])
       when operation in ["version", "status"],
       do: :ok

  defp executable_matches_identity?(%Executable{} = executable, %Identity{} = identity) do
    executable.path == identity.path and executable.device == identity.device and
      executable.inode == identity.inode and executable.size == identity.size and
      executable.mtime == identity.mtime and executable.ctime == identity.ctime and
      executable.mode == identity.mode and executable.sha256 == identity.sha256
  end

  @doc false
  @spec checkout_control_plane_bindings() :: {:ok, map()} | {:error, term()}
  def checkout_control_plane_bindings do
    case AppleContainerControlPlaneAuthority.checkout_bindings() do
      {:ok, bindings} when is_map(bindings) -> {:ok, bindings}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  @doc false
  @spec checkout_image_policy() :: {:ok, map()} | {:error, term()}
  def checkout_image_policy do
    case AppleContainerImagePolicyAuthority.checkout_policy() do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  @doc false
  @spec checkout_baseline_plan() :: {:ok, map()} | {:error, term()}
  def checkout_baseline_plan do
    case LinuxDependencyBaselineAuthority.checkout_plan() do
      {:ok, plan} when is_map(plan) -> {:ok, plan}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  @doc false
  @spec verify_identity(Identity.t()) :: :ok | {:error, term()}
  def verify_identity(%Identity{} = identity) do
    case TrustedPath.verify_pinned(identity) do
      :ok -> :ok
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  def verify_identity(_), do: {:error, :invalid_identity}

  @doc false
  @spec read_plugin_config(Identity.t()) :: {:ok, binary()} | {:error, term()}
  def read_plugin_config(%Identity{} = identity) do
    with :ok <- verify_identity(identity),
         {:ok, bytes} <- read_bounded_regular_file(identity.path, @max_plugin_config_bytes),
         :ok <- require_sha256(bytes, identity.sha256),
         :ok <- verify_identity(identity) do
      {:ok, bytes}
    end
  end

  def read_plugin_config(_), do: {:error, :invalid_plugin_config_identity}

  @doc false
  @spec prove_user_plugin_root_absent() :: :ok | {:error, term()}
  def prove_user_plugin_root_absent do
    child = ControlPlane.user_plugin_root_path()
    parent = Path.dirname(child)

    with {:ok, parent_identity} <- TrustedPath.pin_root_owned_directory(parent),
         :ok <- prove_path_absent(child),
         :ok <- TrustedPath.verify_pinned(parent_identity) do
      :ok
    else
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  # --- Bounded file helpers --------------------------------------------------

  defp read_bounded_regular_file(path, max_bytes)
       when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          case :file.read(io, max_bytes + 1) do
            :eof ->
              {:ok, <<>>}

            {:ok, data} when byte_size(data) > max_bytes ->
              {:error, :plugin_config_too_large}

            {:ok, data} ->
              {:ok, data}

            {:error, _reason} ->
              {:error, :plugin_config_read_failed}
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, :plugin_config_missing}

      {:error, _reason} ->
        {:error, :plugin_config_read_failed}
    end
  end

  defp require_sha256(bytes, expected) when is_binary(bytes) and is_binary(expected) do
    actual =
      :crypto.hash(:sha256, bytes)
      |> Base.encode16(case: :lower)

    if actual == expected do
      :ok
    else
      {:error, :plugin_config_hash_mismatch}
    end
  end

  defp require_sha256(_bytes, _expected), do: {:error, :plugin_config_hash_mismatch}

  defp prove_path_absent(path) when is_binary(path) do
    case :file.read_link_info(String.to_charlist(path)) do
      {:error, :enoent} ->
        :ok

      {:ok, _info} ->
        {:error, :user_plugin_root_present}

      {:error, _reason} ->
        {:error, :user_plugin_root_probe_failed}
    end
  end

  defp bound_reason(reason) when is_atom(reason), do: reason

  defp bound_reason(reason) when is_tuple(reason) do
    components = Tuple.to_list(reason)

    if components != [] and Enum.all?(components, &is_atom/1) do
      reason
    else
      :runtime_operation_failed
    end
  end

  defp bound_reason(_reason), do: :runtime_operation_failed
end
