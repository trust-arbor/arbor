defmodule Arbor.Voice.EgressGrantLedger do
  @moduledoc false

  use GenServer

  alias Arbor.Voice.EgressGrantOwner

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def snapshot, do: call(:snapshot)
  def record(id) when is_binary(id), do: call({:record, id})
  def forget(id) when is_binary(id), do: call({:forget, id})
  def replace_all(ids) when is_list(ids), do: call({:replace_all, ids})

  defp call(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _ -> {:error, :egress_grant_ledger_unavailable}
  end

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    if Process.whereis(EgressGrantOwner),
      do: send(EgressGrantOwner, :egress_grant_ledger_restarted)

    {:ok, MapSet.new()}
  end

  @impl true
  def handle_call(request, {caller, _}, state) do
    if caller == Process.whereis(EgressGrantOwner) do
      handle_owner_call(request, state)
    else
      {:reply, {:error, :egress_grant_ledger_unauthorized}, state}
    end
  end

  defp handle_owner_call(:snapshot, state), do: {:reply, {:ok, state}, state}

  defp handle_owner_call({:record, id}, state) when id != "",
    do: {:reply, :ok, MapSet.put(state, id)}

  defp handle_owner_call({:forget, id}, state),
    do: {:reply, :ok, MapSet.delete(state, id)}

  defp handle_owner_call({:replace_all, ids}, state) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
      do: {:reply, :ok, MapSet.new(ids)},
      else: {:reply, {:error, :invalid_ids}, state}
  end

  defp handle_owner_call(_request, state),
    do: {:reply, {:error, :invalid_request}, state}

  @impl true
  def format_status(%{state: state} = status) when is_struct(state, MapSet),
    do: Map.put(status, :state, %{minted_count: MapSet.size(state)})

  def format_status(status), do: status
end
