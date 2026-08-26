defmodule Arbor.Shell.ValidationRuntime.Authority do
  @moduledoc """
  Imperative owner of the startup-pinned validation-runtime implementation.

  Pins one implementation module at process start under the shared application
  `:boot_epoch` and returns that module on checkout. This owner never executes
  Mix, probes a VM, or interprets a plan: `Arbor.Shell.ValidationRuntime`
  applies the pinned module in the caller.

  Production start pins `ValidationRuntime.AppleContainer`. Application env
  cannot select a backend. Narrow `:implementation` injection is reserved for
  same-library tests.
  """

  use GenServer

  alias Arbor.Shell.StartupEpoch
  alias Arbor.Shell.ValidationRuntime.AppleContainer
  alias Arbor.Shell.ValidationRuntime.Oci

  @epoch_namespace __MODULE__
  @checkout_timeout_ms 5_000
  @default_implementation AppleContainer
  @allowed_start_keys MapSet.new([:name, :boot_epoch, :implementation])

  @type status :: :unavailable | :pinned

  @type state :: %{
          status: status(),
          reason: atom() | nil,
          boot_epoch: reference() | nil,
          implementation: module() | nil,
          driver: String.t()
        }

  @type public_status :: %{
          required(String.t()) => String.t() | nil
        }

  @doc """
  Start the validation-runtime authority owner.

  Production callers pass only the application-generated `:boot_epoch` token.
  Direct-start tests may additionally inject `:name` and/or `:implementation`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with {:ok, name} <- start_name(opts) do
      GenServer.start_link(__MODULE__, opts, name: name)
    end
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
  Checkout of the pinned implementation module.

  Never accepts a caller module. Unavailable or a dead owner fails closed
  without executing.
  """
  @spec checkout_implementation(GenServer.server()) ::
          {:ok, module()} | {:error, :validation_runtime_unavailable}
  def checkout_implementation(server \\ __MODULE__) do
    call(server, :checkout_implementation)
  end

  @doc """
  Redacted public status map. Never includes the implementation module.
  """
  @spec public_status(GenServer.server()) :: public_status()
  def public_status(server \\ __MODULE__) do
    case call(server, :public_status) do
      {:ok, status} when is_map(status) -> status
      _other -> unavailable_public_status(:authority_unavailable)
    end
  end

  @doc false
  @spec clear_boot_epoch(reference() | term()) :: :ok
  def clear_boot_epoch(boot_epoch) when is_reference(boot_epoch) do
    StartupEpoch.clear(@epoch_namespace, boot_epoch)
  end

  def clear_boot_epoch(_boot_epoch), do: :ok

  @impl true
  def init(opts) do
    case normalize_start_opts(opts) do
      {:ok, start_opts} ->
        {:ok, bootstrap(start_opts)}

      {:error, reason} ->
        {:ok,
         %{
           status: :unavailable,
           reason: reason,
           boot_epoch: nil,
           implementation: nil,
           driver: "unavailable"
         }}
    end
  end

  @impl true
  def handle_call(:public_status, _from, state) do
    {:reply, {:ok, render_public_status(state)}, state}
  end

  def handle_call(:checkout_implementation, _from, %{status: :unavailable} = state) do
    {:reply, {:error, :validation_runtime_unavailable}, state}
  end

  def handle_call(
        :checkout_implementation,
        _from,
        %{status: :pinned, implementation: mod} = state
      )
      when is_atom(mod) do
    {:reply, {:ok, mod}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_validation_runtime_authority_request}, state}
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redact_state(state))
    |> redact_status_field(:reason)
    |> redact_status_field(:log)
  end

  def format_status(status), do: status

  defp bootstrap(start_opts) do
    boot_epoch = Map.fetch!(start_opts, :boot_epoch)
    implementation = Map.fetch!(start_opts, :implementation)

    base = %{
      status: :unavailable,
      reason: nil,
      boot_epoch: boot_epoch,
      implementation: nil,
      driver: "unavailable"
    }

    case StartupEpoch.status(@epoch_namespace, boot_epoch) do
      :unbound ->
        base
        |> pin_implementation(implementation)
        |> persist_initial_epoch()

      :bound ->
        repin_boot_epoch(base, implementation)

      {:sealed, :unavailable} ->
        %{base | reason: :boot_epoch_unavailable}

      {:sealed, :unsupported} ->
        poison_epoch(boot_epoch)
        %{base | reason: :boot_epoch_poisoned}

      :poisoned ->
        %{base | reason: :boot_epoch_poisoned}
    end
  end

  defp pin_implementation(base, implementation) do
    %{
      base
      | status: :pinned,
        reason: nil,
        implementation: implementation,
        driver: driver_label(implementation)
    }
  end

  defp persist_initial_epoch(%{boot_epoch: nil} = state), do: state

  defp persist_initial_epoch(%{status: :pinned, implementation: mod} = state)
       when is_atom(mod) do
    case StartupEpoch.bind(@epoch_namespace, state.boot_epoch, epoch_bind_term(mod)) do
      result when result in [:bound, :matched] ->
        state

      :poisoned ->
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, implementation: nil}

      :sealed ->
        poison_epoch(state.boot_epoch)
        %{state | status: :unavailable, reason: :boot_epoch_poisoned, implementation: nil}
    end
  end

  defp repin_boot_epoch(base, implementation) do
    state = pin_implementation(base, implementation)

    case StartupEpoch.bind(@epoch_namespace, base.boot_epoch, epoch_bind_term(implementation)) do
      :matched ->
        state

      :bound ->
        poison_epoch(base.boot_epoch)
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}

      :poisoned ->
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}

      :sealed ->
        poison_epoch(base.boot_epoch)
        %{base | status: :unavailable, reason: :boot_epoch_poisoned}
    end
  end

  defp render_public_status(state) do
    %{
      "state" => Atom.to_string(state.status),
      "reason" => reason_label(state.reason),
      "driver" => state.driver
    }
  end

  defp unavailable_public_status(reason) do
    %{
      "state" => "unavailable",
      "reason" => reason_label(reason),
      "driver" => "unavailable"
    }
  end

  defp reason_label(nil), do: nil
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(_reason), do: "unavailable"

  defp driver_label(AppleContainer), do: "apple_container"
  defp driver_label(Oci), do: "podman"
  defp driver_label(_other), do: "injected"

  defp epoch_bind_term(implementation), do: {:validation_runtime, implementation}

  defp poison_epoch(boot_epoch), do: StartupEpoch.poison(@epoch_namespace, boot_epoch)

  defp redact_state(state) when is_map(state) do
    %{
      status: Map.get(state, :status),
      reason: if(is_nil(Map.get(state, :reason)), do: nil, else: :redacted),
      boot_epoch: if(is_reference(Map.get(state, :boot_epoch)), do: :redacted, else: nil),
      implementation: if(is_atom(Map.get(state, :implementation)), do: :redacted, else: nil),
      driver: Map.get(state, :driver)
    }
  end

  defp redact_state(_state), do: :redacted

  defp redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end

  defp normalize_start_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Enum.reduce_while({:ok, default_start_opts(), MapSet.new()}, &accumulate_start_opt/2)
      |> finish_start_opts()
    else
      {:error, :malformed_validation_runtime_authority_options}
    end
  end

  defp normalize_start_opts(_opts),
    do: {:error, :malformed_validation_runtime_authority_options}

  defp accumulate_start_opt({key, value}, {:ok, acc, seen}) do
    cond do
      not MapSet.member?(@allowed_start_keys, key) ->
        {:halt, {:error, :unknown_validation_runtime_authority_option}}

      MapSet.member?(seen, key) ->
        {:halt, {:error, duplicate_start_option_error(key)}}

      true ->
        put_start_opt(acc, seen, key, value)
    end
  end

  defp accumulate_start_opt(_other, _acc),
    do: {:halt, {:error, :malformed_validation_runtime_authority_options}}

  defp put_start_opt(acc, seen, key, value) do
    case normalize_start_value(key, value) do
      {:ok, normalized} ->
        {:cont, {:ok, Map.put(acc, key, normalized), MapSet.put(seen, key)}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp finish_start_opts({:ok, start_opts, _seen}), do: {:ok, Map.delete(start_opts, :name)}
  defp finish_start_opts({:error, reason}), do: {:error, reason}

  defp default_start_opts do
    %{implementation: @default_implementation, boot_epoch: nil}
  end

  defp normalize_start_value(:name, name), do: validate_start_name(name)

  defp normalize_start_value(:boot_epoch, boot_epoch) when is_reference(boot_epoch),
    do: {:ok, boot_epoch}

  defp normalize_start_value(:boot_epoch, _boot_epoch),
    do: {:error, :invalid_validation_runtime_boot_epoch}

  defp normalize_start_value(:implementation, mod) do
    if valid_implementation?(mod) do
      {:ok, mod}
    else
      {:error, :invalid_validation_runtime_implementation}
    end
  end

  defp valid_implementation?(mod) when is_atom(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        function_exported?(mod, :execute, 3) and function_exported?(mod, :probe, 0) and
          function_exported?(mod, :public_status, 0)

      _other ->
        false
    end
  end

  defp valid_implementation?(_mod), do: false

  defp duplicate_start_option_error(:name), do: :duplicate_validation_runtime_authority_name
  defp duplicate_start_option_error(:boot_epoch), do: :duplicate_validation_runtime_boot_epoch

  defp duplicate_start_option_error(:implementation),
    do: :duplicate_validation_runtime_implementation

  defp start_name(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :name) do
        [] -> {:ok, __MODULE__}
        [name] -> validate_start_name(name)
        _duplicates -> {:error, :duplicate_validation_runtime_authority_name}
      end
    else
      {:error, :malformed_validation_runtime_authority_options}
    end
  end

  defp start_name(_opts), do: {:error, :malformed_validation_runtime_authority_options}

  defp validate_start_name(name) when is_atom(name), do: {:ok, name}
  defp validate_start_name({:global, _term} = name), do: {:ok, name}

  defp validate_start_name({:via, module, _term} = name) when is_atom(module),
    do: {:ok, name}

  defp validate_start_name(_name), do: {:error, :invalid_validation_runtime_authority_name}

  defp call(server, request) do
    case resolve_server(server) do
      {:ok, pid} -> GenServer.call(pid, request, @checkout_timeout_ms)
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :validation_runtime_unavailable}
  end

  defp resolve_server(server) when is_pid(server), do: {:ok, server}

  defp resolve_server(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :validation_runtime_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server({:via, _module, _name} = server) do
    case GenServer.whereis(server) do
      nil -> {:error, :validation_runtime_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server({:global, _term} = server) do
    case GenServer.whereis(server) do
      nil -> {:error, :validation_runtime_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(_server), do: {:error, :validation_runtime_unavailable}
end
