defmodule Arbor.Shell.OciProbeRuntime do
  @moduledoc """
  Production runtime adapter for OCI/Podman admission probing.

  Isolates process execution, authority checkout, and executable pinning so
  `OciProber` can be exercised with a same-library test double. This module
  is not executable spawn authority.
  """

  alias Arbor.Shell.AppleContainerImagePolicyAuthority
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.Executor
  alias Arbor.Shell.LinuxDependencyBaselineAuthority
  alias Arbor.Shell.SpawnCapableTimeout
  alias Arbor.Shell.TrustedPath

  @runtime_path "/usr/bin/podman"
  @max_probe_deadline_ms SpawnCapableTimeout.max_probe_deadline_ms()
  @max_image_json_bytes 262_144
  @probe_option_keys [:clear_env, :cwd, :max_output_bytes, :timeout]
  @sha256_digest_re ~r/\Asha256:[0-9a-f]{64}\z/

  @callback monotonic_ms() :: integer()
  @callback system_architecture() :: charlist() | binary()
  @callback resolve_executable(String.t()) :: {:ok, Executable.t()} | {:error, term()}
  @callback verify_executable(Executable.t()) :: :ok | {:error, term()}
  @callback run_bound(Executable.t(), [String.t()], keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback checkout_image_policy() :: {:ok, map()} | {:error, term()}
  @callback checkout_baseline_plan() :: {:ok, map()} | {:error, term()}

  @doc false
  @spec runtime_path() :: String.t()
  def runtime_path, do: @runtime_path

  @doc false
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc false
  @spec system_architecture() :: charlist() | binary()
  def system_architecture, do: :erlang.system_info(:system_architecture)

  @doc false
  @spec resolve_executable(String.t()) :: {:ok, Executable.t()} | {:error, term()}
  def resolve_executable(@runtime_path = path) do
    with {:ok, _identity} <- pin_distro_runtime(path),
         {:ok, %Executable{path: @runtime_path} = executable} <-
           ExecutablePolicy.resolve(path) do
      {:ok, executable}
    else
      {:ok, %Executable{}} ->
        {:error, :runtime_executable_unavailable}

      {:error, reason} ->
        {:error, bound_resolve_reason(reason)}
    end
  end

  def resolve_executable(path) when is_binary(path), do: {:error, :untrusted_path}
  def resolve_executable(_path), do: {:error, :executable_not_found}

  @doc false
  @spec verify_executable(Executable.t()) :: :ok | {:error, term()}
  def verify_executable(%Executable{path: @runtime_path} = executable) do
    case ExecutablePolicy.verify_pinned(executable) do
      :ok -> :ok
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  def verify_executable(%Executable{}), do: {:error, :untrusted_path}
  def verify_executable(_), do: {:error, :executable_not_pinned}

  @doc false
  @spec run_bound(Executable.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run_bound(%Executable{} = executable, args, opts)
      when is_list(args) and is_list(opts) do
    started_at = monotonic_ms()

    with :ok <- require_runtime_executable(executable),
         {:ok, max_output_bytes} <- reviewed_probe(args),
         :ok <- validate_probe_opts(opts, max_output_bytes),
         {:ok, execution_opts} <- debit_probe_timeout(opts, started_at) do
      case Executor.run_bound(executable, args, execution_opts) do
        {:ok, result} when is_map(result) -> {:ok, result}
        {:error, reason} -> {:error, bound_reason(reason)}
      end
    end
  end

  def run_bound(_executable, _args, _opts), do: {:error, :invalid_run_bound}

  @doc false
  @spec authorize_probe_args(term(), term()) :: :ok | {:error, term()}
  def authorize_probe_args(["image", "inspect", reference], policy)
      when is_binary(reference) and is_map(policy) do
    case execution_digest(policy) do
      {:ok, ^reference} -> :ok
      _other -> {:error, :unreviewed_oci_probe_command}
    end
  end

  def authorize_probe_args(_args, _policy), do: {:error, :unreviewed_oci_probe_command}

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
  @spec execution_digest(map()) :: {:ok, String.t()} | {:error, term()}
  def execution_digest(policy) when is_map(policy) do
    case policy_image(policy) do
      image when is_binary(image) ->
        cond do
          Regex.match?(@sha256_digest_re, image) ->
            {:ok, image}

          match = Regex.run(~r/@sha256:([0-9a-f]{64})\z/, image) ->
            [_, hex] = match
            {:ok, "sha256:" <> hex}

          true ->
            {:error, :not_digest_execution_image}
        end

      _other ->
        {:error, :missing_policy_image}
    end
  end

  def execution_digest(_policy), do: {:error, :invalid_policy}

  defp pin_distro_runtime(path) do
    case TrustedPath.pin_root_owned_regular_file(path, executable: true) do
      {:ok, identity} -> {:ok, identity}
      {:error, :untrusted_path} -> {:error, :untrusted_path}
      {:error, reason} -> {:error, bound_reason(reason)}
    end
  end

  defp policy_image(policy) do
    case Map.fetch(policy, :image) do
      {:ok, value} -> value
      :error -> Map.get(policy, "image")
    end
  end

  defp require_runtime_executable(%Executable{path: @runtime_path}), do: :ok
  defp require_runtime_executable(_), do: {:error, :untrusted_path}

  defp reviewed_probe(["image", "inspect", reference]) when is_binary(reference) do
    if Regex.match?(@sha256_digest_re, reference) do
      {:ok, @max_image_json_bytes}
    else
      {:error, :unreviewed_oci_probe_command}
    end
  end

  defp reviewed_probe(_args), do: {:error, :unreviewed_oci_probe_command}

  defp validate_probe_opts(opts, max_output_bytes) do
    if Keyword.keyword?(opts) do
      keys = opts |> Keyword.keys() |> Enum.sort()
      timeout = Keyword.get(opts, :timeout)
      output_bytes = Keyword.get(opts, :max_output_bytes)

      if keys == @probe_option_keys and Keyword.get(opts, :cwd) == "/" and
           Keyword.get(opts, :clear_env) == true and is_integer(timeout) and timeout > 0 and
           timeout <= @max_probe_deadline_ms and is_integer(output_bytes) and output_bytes > 0 and
           output_bytes <= max_output_bytes do
        :ok
      else
        {:error, :invalid_oci_probe_options}
      end
    else
      {:error, :invalid_oci_probe_options}
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

  defp bound_resolve_reason(:untrusted_path), do: :untrusted_path
  defp bound_resolve_reason(reason), do: bound_reason(reason)

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
