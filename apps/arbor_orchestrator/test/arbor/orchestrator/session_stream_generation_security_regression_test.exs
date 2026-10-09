defmodule Arbor.Orchestrator.SessionStreamGenerationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Orchestrator.TestSupport.SignalsStack
  alias Arbor.Contracts.Session.TurnAuthority

  setup do
    :ok = SignalsStack.ensure!()

    root = Path.join(System.tmp_dir!(), "stream-generation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "turn.dot")

    File.write!(
      path,
      "digraph Turn { start [shape=Mdiamond]; done [shape=Msquare]; start -> done }"
    )

    session =
      start_supervised!(
        {Session,
         [
           session_id: "stream-generation-#{System.unique_integer([:positive])}",
           agent_id: "agent_test",
           turn_dot: path,
           config: %{"recover_session" => false}
         ]}
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{session: session}
  end

  test "security regression: delayed actual producer callbacks cannot append to or publish for the next turn",
       %{session: session} do
    first = make_ref()
    state = arm(session, first)

    opts =
      Builders.build_engine_opts(state, %{},
        source: :turn,
        steering_binding: {first, nil}
      )

    stream = Keyword.fetch!(opts, :on_stream)
    event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    observer = self()

    {:ok, subscription} =
      Arbor.Signals.subscribe(
        "agent.*",
        fn signal ->
          if signal.type in [:stream_delta, :stream_finish] and
               signal.data[:agent_id] == "agent_test",
             do: send(observer, {:turn_signal, signal})

          :ok
        end,
        async: false
      )

    on_exit(fn ->
      if Process.whereis(Arbor.Signals.Bus), do: Arbor.Signals.unsubscribe(subscription)
    end)

    producer =
      spawn(fn ->
        receive do
          :release ->
            stream.(%{type: :delta, data: %{text: "OLD PRIVATE CHUNK"}})
            event.(%{type: :stage_completed, node_id: "old-node", notes: "PRIVATE NOTE"})
            stream.(%{type: :finish})
            # Ordered public barrier on the real receiving Session.
            _ = Session.get_state(session)
            send(observer, :producer_finished)
        end
      end)

    second = make_ref()
    next_state = arm(session, second)
    send(producer, :release)
    assert_receive :producer_finished
    assert :sys.get_state(session).streaming_buffer.content == ""
    assert :sys.get_state(session).turn_progress == nil
    refute_receive {:turn_signal, _}, 100

    next_opts =
      Builders.build_engine_opts(next_state, %{},
        source: :turn,
        steering_binding: {second, nil}
      )

    Keyword.fetch!(next_opts, :on_stream).(%{type: :delta, data: %{"text" => "CURRENT"}})

    Keyword.fetch!(next_opts, :on_event).(%{
      type: :stage_started,
      node_id: "current-node",
      context_updates: %{"private" => "never copied"}
    })

    _ = Session.get_state(session)
    assert :sys.get_state(session).streaming_buffer.content == "CURRENT"

    assert :sys.get_state(session).turn_progress == %{
             type: :stage_started,
             node_id: "current-node"
           }

    assert Session.get_state(session).turn_progress == nil
    assert_receive {:turn_signal, signal}, 1_000
    assert signal.type == :stream_delta
    assert signal.data.delta_length == byte_size("CURRENT")
    refute Map.has_key?(signal.data, :text)

    send(session, {:stream_chunk, "UNQUALIFIED"})
    _ = Session.get_state(session)
    assert :sys.get_state(session).streaming_buffer.content == "CURRENT"
  end

  test "heartbeat and retired internal consultation callbacks cannot enter a human turn", %{
    session: session
  } do
    token = make_ref()
    state = arm(session, token)
    observer = self()

    assert {:ok, subscription} =
             Arbor.Signals.subscribe(
               "agent.stream_delta",
               fn signal ->
                 send(observer, {:heartbeat_signal, signal})
                 :ok
               end,
               async: false
             )

    on_exit(fn ->
      if Process.whereis(Arbor.Signals.Bus), do: Arbor.Signals.unsubscribe(subscription)
    end)

    heartbeat = Builders.build_engine_opts(state, %{}, source: :heartbeat)
    Keyword.fetch!(heartbeat, :on_stream).(%{type: :delta, data: %{text: "HEARTBEAT"}})
    assert_receive {:heartbeat_signal, %{data: %{source: :heartbeat, text: "HEARTBEAT"}}}, 1_000
    refute Keyword.has_key?(heartbeat, :on_event)

    {:ok, authority} =
      TurnAuthority.new(%{
        turn_id: Arbor.Identifiers.generate_id("turn_"),
        authenticated_principal_id: "human_stream_test",
        canonical_owner_id: "human_stream_test"
      })

    consultation = %{
      state
      | turn_authority: authority,
        consultation: %{
          turn_id: authority.turn_id,
          parent_voice_id: "voice_" <> String.duplicate("a", 32)
        }
    }

    opts =
      Builders.build_engine_opts(consultation, %{},
        source: :turn,
        steering_binding: {make_ref(), nil}
      )

    Keyword.fetch!(opts, :on_stream).(%{type: :delta, data: %{text: "CONSULTATION"}})
    Keyword.fetch!(opts, :on_event).(%{type: :stage_started, node_id: "consultation"})
    _ = Session.get_state(session)
    assert :sys.get_state(session).streaming_buffer.content == ""
    assert :sys.get_state(session).turn_progress == nil
  end

  defp arm(session, token) do
    :sys.replace_state(session, fn state ->
      %{
        state
        | turn_in_flight: true,
          turn_token: token,
          streaming_buffer: %{content: "", started_at: DateTime.utc_now(), first_token_at: nil}
      }
      |> Map.put(:turn_progress, nil)
    end)
  end
end
