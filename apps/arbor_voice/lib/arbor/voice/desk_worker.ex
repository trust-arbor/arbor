defmodule Arbor.Voice.DeskWorker do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Arbor.Voice.Redacted

  def start(owner, token, fun) do
    DynamicSupervisor.start_child(
      Arbor.Voice.DeskWorkerSupervisor,
      {__MODULE__, Redacted.new({owner, token, fun})}
    )
  end

  def start_link(%Redacted{} = bootstrap), do: GenServer.start_link(__MODULE__, bootstrap)
  @impl true
  def init(%Redacted{value: {owner, token, fun}} = bootstrap) do
    Process.flag(:sensitive, true)
    Process.link(owner)
    send(self(), :run)
    {:ok, %{owner: owner, token: token, fun: Redacted.new(fun), bootstrap: bootstrap}}
  end

  @impl true
  def handle_info(:run, state) do
    result =
      try do
        Redacted.value(state.fun).()
      rescue
        _ -> {:error, :operation_failed}
      catch
        _, _ -> {:error, :operation_failed}
      end

    send(state.owner, {:desk_work, state.token, Redacted.new(result)})
    {:stop, :normal, state}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
end
