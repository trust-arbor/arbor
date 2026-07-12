defmodule Arbor.Security.SigningAuthorityStateOwner do
  @moduledoc false

  use GenServer

  @empty_snapshot %{authorities: %{}, bootstraps: %{}, open_requests: %{}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec load() :: {:ok, map()} | {:error, :state_owner_unavailable}
  def load do
    try do
      {:ok, GenServer.call(__MODULE__, :load)}
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  @spec replace(map()) :: :ok | {:error, :state_owner_unavailable}
  def replace(snapshot) when is_map(snapshot) do
    try do
      GenServer.call(__MODULE__, {:replace, snapshot})
    catch
      :exit, _reason -> {:error, :state_owner_unavailable}
    end
  end

  @impl true
  def init(_opts), do: {:ok, @empty_snapshot}

  @impl true
  def handle_call(:load, _from, state), do: {:reply, state, state}

  def handle_call({:replace, snapshot}, _from, state) do
    case valid_snapshot?(snapshot) do
      true -> {:reply, :ok, snapshot}
      false -> {:reply, {:error, :state_owner_unavailable}, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

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
