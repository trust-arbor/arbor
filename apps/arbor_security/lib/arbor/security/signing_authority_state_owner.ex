defmodule Arbor.Security.SigningAuthorityStateOwner do
  @moduledoc false

  use GenServer

  alias Arbor.Security.PrivateState
  alias Arbor.Security.SupervisedOwner

  @owner_table :arbor_security_signing_authority_state_owner_directory
  @private_state_anchor {__MODULE__, :private_state}
  @private_state_schema :signing_authority_state_owner_v1

  @empty_snapshot %{
    authorities: %{},
    bootstraps: %{},
    open_requests: %{},
    activation_nonces: %{}
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec load(reference() | nil) ::
          {:ok, map()} | {:error, :state_owner_unavailable | :unauthorized}
  def load(broker_token \\ nil) do
    try do
      case Arbor.Common.authenticated_call(owner_pid(), {:load, broker_token}) do
        snapshot when is_map(snapshot) -> {:ok, snapshot}
        {:error, _reason} = error -> error
      end
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  @doc false
  @spec load_from_supervisor(pid(), reference()) ::
          {:ok, map()} | {:error, :state_owner_unavailable | :unauthorized}
  def load_from_supervisor(supervisor, broker_token)
      when is_pid(supervisor) and is_reference(broker_token) do
    try do
      case state_owner_from_supervisor(supervisor) do
        owner when is_pid(owner) ->
          case Arbor.Common.authenticated_call(
                 owner,
                 {:load_from_supervisor, supervisor, broker_token}
               ) do
            snapshot when is_map(snapshot) -> {:ok, snapshot}
            {:error, _reason} = error -> error
          end

        nil ->
          {:error, :state_owner_unavailable}
      end
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  def load_from_supervisor(_supervisor, _broker_token),
    do: {:error, :state_owner_unavailable}

  @spec replace(map(), reference() | nil) ::
          :ok | {:error, :state_owner_unavailable | :unauthorized}
  def replace(snapshot, broker_token \\ nil) when is_map(snapshot) do
    try do
      Arbor.Common.authenticated_call(owner_pid(), {:replace, broker_token, snapshot})
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  @doc false
  @spec replace_from_supervisor(pid(), map(), reference()) ::
          :ok | {:error, :state_owner_unavailable | :unauthorized}
  def replace_from_supervisor(supervisor, snapshot, broker_token)
      when is_pid(supervisor) and is_map(snapshot) and is_reference(broker_token) do
    try do
      case state_owner_from_supervisor(supervisor) do
        owner when is_pid(owner) ->
          Arbor.Common.authenticated_call(
            owner,
            {:replace_from_supervisor, supervisor, broker_token, snapshot}
          )

        nil ->
          {:error, :state_owner_unavailable}
      end
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  def replace_from_supervisor(_supervisor, _snapshot, _broker_token),
    do: {:error, :state_owner_unavailable}

  @doc false
  def pid, do: owner_pid()

  @doc false
  @spec pid_from_supervisor(pid()) :: pid() | nil
  def pid_from_supervisor(supervisor) when is_pid(supervisor),
    do: state_owner_from_supervisor(supervisor)

  def pid_from_supervisor(_supervisor), do: nil

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    with {:ok, broker_token} <- Keyword.fetch(opts, :broker_token),
         true <- is_reference(broker_token),
         {:ok, supervisor_pid} <- startup_supervisor_pid(),
         :ok <- claim_directory() do
      state = %{
        broker_token: broker_token,
        snapshot: @empty_snapshot,
        authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
        security_supervisor_pid: supervisor_pid
      }

      {:ok, PrivateState.new(@private_state_anchor, @private_state_schema, state)}
    else
      false -> {:stop, :invalid_broker_token}
      :error -> {:stop, :invalid_broker_token}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(_request, _from, private_state),
    do: {:reply, {:error, :unauthorized}, private_state}

  defp handle_authenticated_request({:load, broker_token}, caller_pid, state) do
    if authorized_broker?(caller_pid, broker_token, state) do
      {:reply, state.snapshot, state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  defp handle_authenticated_request(
         {:load_from_supervisor, supervisor, broker_token},
         caller_pid,
         state
       ) do
    if authorized_broker_from_supervisor?(caller_pid, supervisor, broker_token, state) do
      {:reply, state.snapshot, state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  defp handle_authenticated_request({:replace, broker_token, snapshot}, caller_pid, state) do
    case {authorized_broker?(caller_pid, broker_token, state), valid_snapshot?(snapshot)} do
      {true, true} -> {:reply, :ok, %{state | snapshot: snapshot}}
      {true, false} -> {:reply, {:error, :state_owner_unavailable}, state}
      {false, _} -> {:reply, {:error, :unauthorized}, state}
    end
  end

  defp handle_authenticated_request(
         {:replace_from_supervisor, supervisor, broker_token, snapshot},
         caller_pid,
         state
       ) do
    case {authorized_broker_from_supervisor?(caller_pid, supervisor, broker_token, state),
          valid_snapshot?(snapshot)} do
      {true, true} -> {:reply, :ok, %{state | snapshot: snapshot}}
      {true, false} -> {:reply, {:error, :state_owner_unavailable}, state}
      {false, _} -> {:reply, {:error, :unauthorized}, state}
    end
  end

  defp handle_authenticated_request(_request, _caller, state),
    do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_info(message, private_state) do
    with {:ok, state} <- private_state(private_state) do
      case handle_private_info(message, state) do
        {:noreply, next_state} ->
          case put_private_state(private_state, next_state) do
            :ok -> {:noreply, private_state}
            {:error, _reason} -> {:stop, :invalid_private_state, private_state}
          end
      end
    else
      {:error, _reason} -> {:stop, :invalid_private_state, private_state}
    end
  end

  defp handle_private_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        {:reply, reply, next_state} = handle_authenticated_request(request, caller, state)
        :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
        {:noreply, next_state}

      result when result in [:pending, :expired, :rejected, :unrecognized] ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    state =
      case private_state(Map.get(status, :state, %{})) do
        {:ok, owner_state} -> owner_state.snapshot
        {:error, _reason} -> %{}
      end

    redacted = %{
      authority_count: map_count(state, :authorities),
      bootstrap_count: map_count(state, :bootstraps),
      open_request_count: map_count(state, :open_requests),
      activation_nonce_count: map_count(state, :activation_nonces)
    }

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redacted)
    |> redact_field(:reason)
    |> redact_field(:log)
  end

  @impl true
  def terminate(_reason, private_state) do
    PrivateState.delete(private_state, @private_state_anchor)
    :ok
  end

  defp private_state(state) do
    PrivateState.fetch(
      state,
      @private_state_anchor,
      @private_state_schema,
      &valid_private_state?/1
    )
  end

  defp put_private_state(handle, state) do
    PrivateState.replace(
      handle,
      @private_state_anchor,
      @private_state_schema,
      state,
      &valid_private_state?/1
    )
  end

  defp valid_private_state?(state) when is_map(state) do
    Map.keys(state) |> Enum.sort() ==
      [:authenticated_calls, :broker_token, :security_supervisor_pid, :snapshot] and
      is_reference(state.authenticated_calls) and is_reference(state.broker_token) and
      is_pid(state.security_supervisor_pid) and valid_snapshot?(state.snapshot)
  end

  defp valid_private_state?(_state), do: false

  defp valid_snapshot?(snapshot) do
    Map.keys(snapshot) |> Enum.sort() ==
      [:activation_nonces, :authorities, :bootstraps, :open_requests] and
      Enum.all?(Map.values(snapshot), &is_map/1)
  end

  defp authorized_broker?(caller_pid, broker_token, state) do
    is_reference(broker_token) and broker_token === state.broker_token and
      authorized_broker_pid?(caller_pid, state.security_supervisor_pid)
  end

  defp authorized_broker_from_supervisor?(caller_pid, supervisor, broker_token, state) do
    is_pid(supervisor) and supervisor === state.security_supervisor_pid and
      is_reference(broker_token) and broker_token === state.broker_token and
      authorized_broker_pid?(caller_pid, supervisor)
  end

  defp authorized_broker_pid?(caller_pid, supervisor)
       when is_pid(caller_pid) and is_pid(supervisor) do
    SupervisedOwner.child_pid(supervisor, __MODULE__) == self() and
      SupervisedOwner.child_pid(supervisor, Arbor.Security.SigningAuthorityBroker) == caller_pid
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp authorized_broker_pid?(_caller_pid, _supervisor), do: false

  defp startup_supervisor_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> linked_supervisor(pid)
      [name | _] when is_atom(name) -> name |> Process.whereis() |> linked_supervisor()
      _other -> {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(pid) when is_pid(pid) do
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if pid in links,
          do: {:ok, pid},
          else: {:error, :security_supervisor_unavailable}

      _other ->
        {:error, :security_supervisor_unavailable}
    end
  end

  defp linked_supervisor(_pid), do: {:error, :security_supervisor_unavailable}

  defp claim_directory do
    table = :ets.new(@owner_table, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :state_owner_directory_unavailable}
  end

  defp owner_pid do
    case SupervisedOwner.protected_directory_owner(
           @owner_table,
           :owner,
           :arbor_security,
           [__MODULE__]
         ) do
      pid when is_pid(pid) -> pid
      nil -> raise "state owner unavailable"
    end
  end

  defp state_owner_from_supervisor(supervisor) do
    SupervisedOwner.child_pid(supervisor, __MODULE__)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp map_count(state, key) do
    case Map.get(state, key) do
      value when is_map(value) -> map_size(value)
      _ -> 0
    end
  end

  defp redact_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end
