defmodule Arbor.Actions.ContinuationExecutionWitness do
  @moduledoc false

  use GenServer

  alias Arbor.Actions

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  def issue(server, scope), do: GenServer.call(server, {:arm, scope})

  def abort(server, continuation_id),
    do: GenServer.call(server, {:abort, continuation_id})

  def invalidate(server, continuation_id, generation),
    do: GenServer.call(server, {:invalidate, continuation_id, generation})

  @impl true
  def init(name) do
    case Actions.bind_continuation_execution_witness(name) do
      :ok -> {:ok, %{name: name}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:arm, scope}, _from, state) do
    {:reply, Actions.arm_coding_cross_app_continuation_execution(scope), state}
  end

  def handle_call({:abort, continuation_id}, _from, state) do
    {:reply, Actions.abort_coding_cross_app_continuation_execution(continuation_id), state}
  end

  def handle_call({:invalidate, continuation_id, generation}, _from, state) do
    {:reply,
     Actions.invalidate_coding_cross_app_continuation_execution(continuation_id, generation),
     state}
  end
end
