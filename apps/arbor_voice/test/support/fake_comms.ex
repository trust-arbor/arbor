defmodule Arbor.Voice.Test.FakeComms do
  @moduledoc """
  Process-local fake of the public `Arbor.Comms.record_engagement_turn/5`
  facade for `Arbor.Voice.TranscriptRecorder` hermetic tests (VP-04D2A).

  Install the Agent target via `install/1` (or `start/1`) before calling the
  recorder with `comms: __MODULE__`. Call history is owned by the ExUnit
  process's Agent so evidence is exact and network-free.
  """

  @agent_key {__MODULE__, :agent}

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    result = Keyword.get(opts, :result, {:ok, 2})
    Agent.start_link(fn -> %{result: result, calls: []} end)
  end

  @doc "Bind this fake module to `agent` for the current process."
  @spec install(pid()) :: :ok
  def install(agent) when is_pid(agent) do
    Process.put(@agent_key, agent)
    :ok
  end

  @doc "Start an Agent and install it for the current process."
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts \\ []) do
    {:ok, agent} = start_link(opts)
    install(agent)
    {:ok, agent}
  end

  @spec calls(pid()) :: [tuple()]
  def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

  @spec call_count(pid()) :: non_neg_integer()
  def call_count(agent), do: Agent.get(agent, &length(&1.calls))

  @spec set_result(pid(), term()) :: :ok
  def set_result(agent, result), do: Agent.update(agent, &%{&1 | result: result})

  @doc "Same public shape as `Arbor.Comms.record_engagement_turn/5`."
  @spec record_engagement_turn(term(), term(), term(), term(), keyword()) :: term()
  def record_engagement_turn(agent_id, engagement_id, user_entry, assistant_entry, opts) do
    agent = Process.get(@agent_key) || raise "FakeComms not installed for this process"

    Agent.get_and_update(agent, fn state ->
      call = {agent_id, engagement_id, user_entry, assistant_entry, opts}
      {state.result, %{state | calls: [call | state.calls]}}
    end)
  end
end
