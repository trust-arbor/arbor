defmodule Arbor.Shell.AppleContainerControlPlaneAuthority do
  @moduledoc """
  Imperative owner of startup-pinned Apple Container control-plane bindings.

  Pins fixed control-plane artifacts and operator-configured kernel/app-root
  locators at process start, holds those bindings privately, and re-verifies
  them on internal checkout. This module is not executable authority by itself
  and does not admit container workloads or launch processes.

  Production Application startup starts this owner with no authority-bearing
  options. Narrow direct-start injection is reserved for same-library tests.
  """

  use GenServer

  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.Config
  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @type status :: :unsupported | :unavailable | :pinned

  @type state :: %{
          status: status(),
          reason: atom() | nil,
          platform: atom(),
          trusted_path: module(),
          bindings: map() | nil
        }

  @type public_status :: %{
          required(String.t()) => String.t() | nil
        }

  @allowed_start_keys MapSet.new([:name, :trusted_path, :host_platform])

  @doc """
  Start the control-plane authority owner.

  Production callers must pass no authority-bearing options. Direct-start tests
  may inject `:name`, `:trusted_path`, and/or `:host_platform` only.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = List.wrap(opts)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Child specification for the application supervisor.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = List.wrap(opts)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Internal checkout of owner-held control-plane bindings.

  Never accepts caller bindings. When pinned, re-verifies every identity and
  re-canonicalizes `app_root` before returning a shallow copy of the owner map.
  Drift terminates this owner abnormally so `rest_for_one` tears down later
  execution owners.
  """
  @spec checkout_bindings(GenServer.server()) ::
          {:ok, map()}
          | {:error, :control_plane_unsupported | :control_plane_unavailable | term()}
  def checkout_bindings(server \\ __MODULE__) do
    call(server, :checkout_bindings)
  end

  @doc """
  Redacted public status map. Never includes identities, digests, or app_root.
  """
  @spec public_status(GenServer.server()) :: public_status()
  def public_status(server \\ __MODULE__) do
    case call(server, :public_status) do
      {:ok, status} when is_map(status) -> status
      _other -> unavailable_public_status(:authority_unavailable)
    end
  end

  @impl true
  def init(opts) do
    case normalize_start_opts(opts) do
      {:ok, start_opts} ->
        platform = Map.fetch!(start_opts, :host_platform)
        trusted_path = Map.fetch!(start_opts, :trusted_path)
        {:ok, bootstrap(platform, trusted_path)}

      {:error, reason} ->
        # Reject authority-bearing start injection without crashing the app:
        # surface as a live unavailable owner rather than a boot loop.
        {:ok,
         %{
           status: :unavailable,
           reason: reason,
           platform: detect_host_platform(),
           trusted_path: TrustedPath,
           bindings: nil
         }}
    end
  end

  @impl true
  def handle_call(:public_status, _from, state) do
    {:reply, {:ok, render_public_status(state)}, state}
  end

  def handle_call(:checkout_bindings, _from, %{status: :unsupported} = state) do
    {:reply, {:error, :control_plane_unsupported}, state}
  end

  def handle_call(:checkout_bindings, _from, %{status: :unavailable} = state) do
    {:reply, {:error, :control_plane_unavailable}, state}
  end

  def handle_call(:checkout_bindings, _from, %{status: :pinned, bindings: bindings} = state)
      when is_map(bindings) do
    case reverify_bindings(state.trusted_path, bindings) do
      :ok ->
        {:reply, {:ok, Map.new(bindings)}, state}

      {:error, reason} ->
        {:stop, {:control_plane_identity_drift, reason},
         {:error, {:control_plane_identity_drift, reason}}, state}
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_control_plane_authority_request}, state}
  end

  @impl true
  def format_status(status) when is_map(status) do
    case Map.get(status, :state) do
      state when is_map(state) ->
        Map.put(status, :state, redact_state(state))

      _other ->
        status
    end
  end

  def format_status(status), do: status

  # --- Bootstrap -------------------------------------------------------------

  defp bootstrap(platform, trusted_path) do
    base = %{
      status: :unavailable,
      reason: nil,
      platform: platform,
      trusted_path: trusted_path,
      bindings: nil
    }

    cond do
      platform != :darwin_arm64 ->
        %{base | status: :unsupported, reason: :unsupported_host}

      true ->
        pin_from_config(base, trusted_path)
    end
  end

  defp pin_from_config(base, trusted_path) do
    case Config.apple_container() do
      {:ok, %{kernel_path: kernel_path, app_root: app_root}} ->
        case pin_bindings(trusted_path, kernel_path, app_root) do
          {:ok, bindings} ->
            %{base | status: :pinned, reason: nil, bindings: bindings}

          {:error, reason} ->
            %{base | status: :unavailable, reason: reason, bindings: nil}
        end

      {:error, :apple_container_config_absent} ->
        %{base | status: :unavailable, reason: :missing_config, bindings: nil}

      {:error, reason} ->
        %{base | status: :unavailable, reason: reason, bindings: nil}
    end
  end

  defp pin_bindings(trusted_path, kernel_path, app_root) do
    with {:ok, cli_identity} <-
           pin_identity(trusted_path, ControlPlane.cli_path(), true, :cli_identity),
         {:ok, apiserver_identity} <-
           pin_identity(trusted_path, ControlPlane.apiserver_path(), true, :apiserver_identity),
         {:ok, runtime_plugin_identity} <-
           pin_identity(trusted_path, ControlPlane.plugin_path(), true, :runtime_plugin_identity),
         {:ok, runtime_plugin_config_identity} <-
           pin_identity(
             trusted_path,
             ControlPlane.plugin_config_path(),
             false,
             :runtime_plugin_config_identity
           ),
         {:ok, kernel_identity} <-
           pin_identity(trusted_path, kernel_path, false, :kernel_identity),
         {:ok, pinned_app_root} <- pin_app_root(trusted_path, app_root) do
      {:ok,
       %{
         cli_identity: cli_identity,
         apiserver_identity: apiserver_identity,
         runtime_plugin_identity: runtime_plugin_identity,
         runtime_plugin_config_identity: runtime_plugin_config_identity,
         kernel_identity: kernel_identity,
         app_root: pinned_app_root
       }}
    end
  end

  defp pin_identity(trusted_path, expected_path, executable?, label) do
    case trusted_path.pin_root_owned_regular_file(expected_path, executable: executable?) do
      {:ok, %Identity{path: ^expected_path, executable_required: ^executable?} = identity} ->
        {:ok, identity}

      {:ok, %Identity{path: other_path}} when other_path != expected_path ->
        {:error, {:identity_path_mismatch, label}}

      {:ok, %Identity{executable_required: other}} when other != executable? ->
        {:error, {:identity_executable_mismatch, label}}

      {:ok, _other} ->
        {:error, {:invalid_identity, label}}

      {:error, reason} ->
        {:error, {:pin_failed, label, reason}}
    end
  end

  defp pin_app_root(trusted_path, configured_app_root) do
    case trusted_path.canonicalize_absolute(configured_app_root) do
      {:ok, ^configured_app_root} ->
        {:ok, configured_app_root}

      {:ok, _other} ->
        {:error, :app_root_not_canonical}

      {:error, reason} ->
        {:error, {:app_root_canonicalize_failed, reason}}
    end
  end

  defp reverify_bindings(trusted_path, bindings) do
    identities = [
      bindings.cli_identity,
      bindings.apiserver_identity,
      bindings.runtime_plugin_identity,
      bindings.runtime_plugin_config_identity,
      bindings.kernel_identity
    ]

    with :ok <- reverify_identities(trusted_path, identities),
         :ok <- reverify_app_root(trusted_path, bindings.app_root) do
      :ok
    end
  end

  defp reverify_identities(trusted_path, identities) do
    Enum.reduce_while(identities, :ok, fn identity, :ok ->
      case trusted_path.verify_pinned(identity) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reverify_app_root(trusted_path, app_root) do
    case trusted_path.canonicalize_absolute(app_root) do
      {:ok, ^app_root} -> :ok
      {:ok, _other} -> {:error, :app_root_not_canonical}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Start-option normalization --------------------------------------------

  defp normalize_start_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Enum.reduce_while(opts, {:ok, default_start_opts()}, fn
        {key, value}, {:ok, acc} ->
          if MapSet.member?(@allowed_start_keys, key) do
            case normalize_start_value(key, value) do
              {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:halt, {:error, :unknown_control_plane_authority_option}}
          end

        _other, _acc ->
          {:halt, {:error, :malformed_control_plane_authority_options}}
      end)
      |> case do
        {:ok, start_opts} -> {:ok, Map.delete(start_opts, :name)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :malformed_control_plane_authority_options}
    end
  end

  defp normalize_start_opts(_opts), do: {:error, :malformed_control_plane_authority_options}

  defp default_start_opts do
    %{
      trusted_path: TrustedPath,
      host_platform: detect_host_platform()
    }
  end

  defp normalize_start_value(:name, name)
       when is_atom(name) or is_pid(name) or is_tuple(name) do
    {:ok, name}
  end

  defp normalize_start_value(:name, _name), do: {:error, :invalid_control_plane_authority_name}

  defp normalize_start_value(:trusted_path, module) when is_atom(module) do
    {:ok, module}
  end

  defp normalize_start_value(:trusted_path, _module),
    do: {:error, :invalid_control_plane_trusted_path}

  defp normalize_start_value(:host_platform, platform) when is_atom(platform) do
    {:ok, platform}
  end

  defp normalize_start_value(:host_platform, _platform),
    do: {:error, :invalid_control_plane_host_platform}

  defp detect_host_platform do
    case {:os.type(), :erlang.system_info(:system_architecture)} do
      {{:unix, :darwin}, arch} when is_list(arch) ->
        arch_string = List.to_string(arch)

        if String.starts_with?(arch_string, "aarch64") or
             String.contains?(arch_string, "arm64") do
          :darwin_arm64
        else
          :unsupported
        end

      _other ->
        :unsupported
    end
  end

  # --- Presentation / redaction ----------------------------------------------

  defp render_public_status(state) do
    %{
      "state" => Atom.to_string(state.status),
      "reason" => reason_label(state.reason),
      "platform" => Atom.to_string(state.platform)
    }
  end

  defp unavailable_public_status(reason) do
    %{
      "state" => "unavailable",
      "reason" => reason_label(reason),
      "platform" => "unknown"
    }
  end

  defp reason_label(nil), do: nil
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_label(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map_join(".", &reason_component/1)
  end

  defp reason_label(_reason), do: "unavailable"

  defp reason_component(value) when is_atom(value), do: Atom.to_string(value)
  defp reason_component(value) when is_binary(value), do: value
  defp reason_component(_value), do: "detail"

  defp redact_state(state) when is_map(state) do
    %{
      status: Map.get(state, :status),
      reason: Map.get(state, :reason),
      platform: Map.get(state, :platform),
      trusted_path: Map.get(state, :trusted_path),
      bindings: if(is_map(Map.get(state, :bindings)), do: :redacted, else: nil)
    }
  end

  defp call(server, request) do
    case resolve_server(server) do
      {:ok, pid} -> GenServer.call(pid, request)
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :control_plane_authority_unavailable}
  end

  defp resolve_server(server) when is_pid(server), do: {:ok, server}

  defp resolve_server(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :control_plane_authority_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server({:via, _module, _name} = server) do
    case GenServer.whereis(server) do
      nil -> {:error, :control_plane_authority_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(_server), do: {:error, :control_plane_authority_unavailable}
end
