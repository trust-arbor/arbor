defmodule ConversationTransportProbe do
  alias ArborTui.App

  def run do
    info = File.read!("/private/tmp/convergence-transport.json") |> Jason.decode!()
    identity = %{agent_id: info["principal"], private_key: Base.decode64!(info["private_key"])}

    state =
      App.init(
        identity: identity,
        runtime_name: self(),
        gateway_url: info["gateway"],
        target_agent_id: info["target"]
      )
      |> Map.put(:state_path, "/private/tmp/convergence-transport-tui.state")

    state =
      await(state, fn s ->
        s.status == :connected and inspect(s.messages) =~ "BROWSER-LARCH-217"
      end)

    {state} = App.update(:submit, %{state | input: "TERMINAL-CEDAR-842"})

    state =
      await(state, fn s ->
        s[:delivery_status] == "completed" and length(:sys.get_state(s.ws).history) == 4
      end)

    original = :sys.get_state(state.ws)
    :ok = Mint.HTTP.close(original.conn) |> close_result()

    state =
      await(state, fn s ->
        transport = :sys.get_state(s.ws)

        s.status == :connected and transport.conn != nil and transport.ref != original.ref and
          transport.history_cursor == 4
      end)

    {state} = App.update(:submit, %{state | input: "/retry"})

    state =
      await(state, fn s ->
        :sys.get_state(s.ws).command_attempts == 2 and s[:delivery_status] == "completed"
      end)

    state = drain(state, 1_300)
    transport = :sys.get_state(state.ws)

    unless transport.history_cursor == 4 and transport.event_cursor == 6,
      do: raise("cursor mismatch")

    rendered = inspect(App.view(state), limit: :infinity, printable_limit: :infinity)

    unless rendered =~ "BROWSER-LARCH-217" and rendered =~ "TERMINAL-CEDAR-842",
      do: raise("renderer omitted transcript")

    result = %{
      stage: "reconnected_and_retried",
      history_cursor: transport.history_cursor,
      journal_cursor: transport.event_cursor,
      command_id: transport.last_command["id"],
      engagement_id: transport.engagement_id,
      transcript_entries: length(transport.history),
      real_client: "ArborTui.WSClient",
      renderer: "ArborTui.App.view",
      pty: false
    }

    File.write!("/private/tmp/convergence-transport-tui-result.json", Jason.encode!(result))
    File.write!("/private/tmp/convergence-transport-tui-render.txt", rendered)
    IO.puts("TERMINAL_RECONNECTED_AND_RETRIED")
    state = await(state, fn s -> s.status == :detached end, 600_000)

    unless :sys.get_state(state.ws).target_agent_id == nil,
      do: raise("revoked terminal still attached")

    File.write!(
      "/private/tmp/convergence-transport-tui-result.json",
      Jason.encode!(Map.put(result, :stage, "revoked_and_detached"))
    )

    IO.puts("TERMINAL_REVOCATION_PASSED")
  end

  defp close_result({:ok, _}), do: :ok
  defp close_result(:ok), do: :ok

  defp await(state, predicate, timeout \\ 60_000),
    do: wait(state, predicate, System.monotonic_time(:millisecond) + timeout)

  defp wait(state, predicate, deadline) do
    if predicate.(state) do
      state
    else
      if System.monotonic_time(:millisecond) > deadline,
        do:
          raise(
            "client wait timed out: #{inspect(Map.take(state, [:status, :status_detail, :messages, :delivery_status]))}"
          )

      wait(next(state, 50), predicate, deadline)
    end
  end

  defp next(state, timeout) do
    receive do
      {:"$gen_cast", {:message, :root, message}} -> elem(App.update(message, state), 0)
    after
      timeout -> state
    end
  end

  defp drain(state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(state, fn _ -> System.monotonic_time(:millisecond) >= deadline end, deadline + 500)
  end
end

ConversationTransportProbe.run()
