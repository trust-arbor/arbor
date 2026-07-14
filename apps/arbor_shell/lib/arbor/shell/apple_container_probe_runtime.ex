defmodule Arbor.Shell.AppleContainerProbeRuntime do
  @moduledoc """
  Production runtime adapter for Apple Container admission probing.

  Isolates process execution, authority checkout, and bounded file IO so
  `AppleContainerProber` can be exercised with a same-library test double.
  This module is not executable spawn authority.
  """

  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.AppleContainerControlPlaneAuthority
  alias Arbor.Shell.AppleContainerImagePolicyAuthority
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.Executor
  alias Arbor.Shell.LinuxDependencyBaselineAuthority
  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @max_plugin_config_bytes 8_192

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
    case Executor.run_bound(executable, args, opts) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  def run_bound(_executable, _args, _opts), do: {:error, :invalid_run_bound}

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
