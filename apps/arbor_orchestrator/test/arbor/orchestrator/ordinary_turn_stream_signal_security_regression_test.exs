defmodule Arbor.Orchestrator.OrdinaryTurnStreamSignalSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Session
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Orchestrator.TestSupport.SignalsStack

  @moduletag :fast
  @moduletag :security_regression
  @private_chunk "PRIVATE ordinary café turn 🌲"

  setup do
    :ok = SignalsStack.ensure!()

    id = "ordinary-stream-privacy-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(root)
    path = Path.join(root, "turn.dot")

    File.write!(
      path,
      "digraph Turn { start [shape=Mdiamond]; done [shape=Msquare]; start -> done }"
    )

    session =
      start_supervised!(
        {Session,
         session_id: id,
         agent_id: "agent_test",
         turn_dot: path,
         config: %{"recover_session" => false}}
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{session: session, session_id: id}
  end

  test "security regression: current ordinary turn stream publishes metadata without private text",
       %{session: session, session_id: session_id} do
    token = make_ref()

    state =
      :sys.replace_state(session, fn state ->
        %{
          state
          | turn_in_flight: true,
            turn_token: token,
            streaming_buffer: %{content: "", started_at: DateTime.utc_now(), first_token_at: nil}
        }
      end)

    observer = self()
    tag = make_ref()

    assert {:ok, subscription} =
             Arbor.Signals.subscribe(
               "agent.stream_delta",
               fn signal ->
                 if signal.data[:session_id] == session_id, do: send(observer, {tag, signal})
                 :ok
               end,
               async: false
             )

    on_exit(fn ->
      if Process.whereis(Arbor.Signals.Bus), do: Arbor.Signals.unsubscribe(subscription)
    end)

    opts = Builders.build_engine_opts(state, %{}, source: :turn, steering_binding: {token, nil})
    Keyword.fetch!(opts, :on_stream).(%{type: :delta, data: %{text: @private_chunk}})
    _ = Session.get_state(session)

    assert_receive {^tag, %{type: :stream_delta, data: data}}, 1_000
    refute Map.has_key?(data, :text)
    assert data.delta_length == byte_size(@private_chunk)
    assert :sys.get_state(session).streaming_buffer.content == @private_chunk
  end
end
