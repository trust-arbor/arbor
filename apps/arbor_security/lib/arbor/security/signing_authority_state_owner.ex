defmodule Arbor.Security.SigningAuthorityStateOwner do
  @moduledoc false

  use GenServer

  @empty_snapshot %{authorities: %{}, bootstraps: %{}, open_requests: %{}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec load(reference() | nil) ::
          {:ok, map()} | {:error, :state_owner_unavailable | :unauthorized}
  def load(broker_token \\ nil) do
    try do
      case GenServer.call(__MODULE__, {:load, broker_token}) do
        snapshot when is_map(snapshot) -> {:ok, snapshot}
        {:error, _reason} = error -> error
      end
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  @spec replace(map(), reference() | nil) ::
          :ok | {:error, :state_owner_unavailable | :unauthorized}
  def replace(snapshot, broker_token \\ nil) when is_map(snapshot) do
    try do
      GenServer.call(__MODULE__, {:replace, broker_token, snapshot})
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :broker_token) do
      {:ok, broker_token} when is_reference(broker_token) ->
        {:ok, %{broker_token: broker_token, snapshot: @empty_snapshot}}

      _ ->
        {:stop, :invalid_broker_token}
    end
  end

  @impl true
  def handle_call({:load, broker_token}, {caller_pid, _tag}, state) do
    if authorized_broker?(caller_pid, broker_token, state) do
      {:reply, state.snapshot, state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call({:replace, broker_token, snapshot}, {caller_pid, _tag}, state) do
    case {authorized_broker?(caller_pid, broker_token, state), valid_snapshot?(snapshot)} do
      {true, true} -> {:reply, :ok, %{state | snapshot: snapshot}}
      {true, false} -> {:reply, {:error, :state_owner_unavailable}, state}
      {false, _} -> {:reply, {:error, :unauthorized}, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    owner_state = Map.get(status, :state, %{})
    state = Map.get(owner_state, :snapshot, %{})

    redacted = %{
      authority_count: map_count(state, :authorities),
      bootstrap_count: map_count(state, :bootstraps),
      open_request_count: map_count(state, :open_requests)
    }

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redacted)
    |> redact_field(:reason)
    |> redact_field(:log)
  end

  defp valid_snapshot?(snapshot) do
    Map.keys(snapshot) |> Enum.sort() == [:authorities, :bootstraps, :open_requests] and
      Enum.all?(Map.values(snapshot), &is_map/1)
  end

  defp authorized_broker?(caller_pid, broker_token, state) do
    caller_pid == Process.whereis(Arbor.Security.SigningAuthorityBroker) and
      is_reference(broker_token) and broker_token === state.broker_token
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
