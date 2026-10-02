defmodule Arbor.Voice.Backend.XaiPassiveTransportTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Backend.XaiRealtime.Transport

  @moduletag :fast

  defmodule PassiveWebsocket do
    def recv(%{reads: [{data, elapsed} | rest]} = conn, 0, timeout) do
      send(self(), {:passive_read, timeout})
      Process.put(conn.clock_key, Process.get(conn.clock_key, 0) + elapsed)
      latest = %{conn | reads: rest, generation: conn.generation + 1}

      case data do
        :timeout -> {:error, latest, :timeout, []}
        bytes -> {:ok, latest, [{:data, conn.ref, bytes}]}
      end
    end
  end

  defmodule PassiveTransport do
    def connect(opts), do: {:ok, Keyword.fetch!(opts, :fixture_state)}
    def recv_frame(state, timeout), do: Transport.recv_frame(state, timeout, PassiveWebsocket)
    def close(_state), do: :ok
  end

  test "partial WebSocket data survives a passive timeout and drains pending events without mailbox loss" do
    first = %{"type" => "response.output_text.delta", "delta" => "first"}
    second = %{"type" => "response.done"}
    <<prefix::binary-size(7), suffix::binary>> = wire_frame(first)
    control = <<0x89, 0>>
    initial = state([{control <> prefix, 0}, {:timeout, 0}, {suffix <> wire_frame(second), 0}])
    send(self(), :foreign_mailbox_message)

    assert {:error, :timeout, latest} = Transport.recv_frame(initial, 100, PassiveWebsocket)
    assert latest.conn.generation == 2
    assert latest.ws != initial.ws
    assert_receive :foreign_mailbox_message
    assert_receive {:passive_read, 100}
    assert_receive {:passive_read, 100}

    assert {:ok, latest, ^first} = Transport.recv_frame(latest, 100, PassiveWebsocket)
    assert latest.conn.generation == 3
    assert_receive {:passive_read, 100}
    assert {:ok, drained, ^second} = Transport.recv_frame(latest, 100, PassiveWebsocket)
    assert drained.conn.generation == 3
    assert drained.pending == []
    refute_receive {:passive_read, _}, 0
  end

  test "control frames share one absolute passive-read deadline and retain consumed state" do
    control = <<0x89, 0>>
    trailing = wire_frame(%{"type" => "response.done"})
    initial = state([{control, 40}, {control, 40}, {control, 40}, {trailing, 0}])

    assert {:error, :timeout, latest} = Transport.recv_frame(initial, 100, PassiveWebsocket)
    assert latest.conn.generation == 3
    assert latest.conn.reads == [{trailing, 0}]
    assert_receive {:passive_read, 100}
    assert_receive {:passive_read, 60}
    assert_receive {:passive_read, 20}
    refute_receive {:passive_read, _}, 0
  end

  test "backend timeout carries partial transport progress into its next receive" do
    event = %{"type" => "response.output_text.delta", "delta" => "complete"}
    <<prefix::binary-size(8), suffix::binary>> = wire_frame(event)
    initial = state([{wire_frame(%{"type" => "ping"}) <> prefix, 0}, {:timeout, 0}, {suffix, 0}])

    assert {:ok, session} =
             XaiRealtime.open(
               transport: PassiveTransport,
               transport_opts: [fixture_state: initial],
               clock_fun: initial.clock_fun,
               effect_authorizer: fn _, _ -> :allow end,
               oauth_resolver: fn :xai -> {:ok, "fixture-token"} end
             )

    assert {:error, :timeout, latest} = XaiRealtime.recv(session, 100)
    assert latest.transport_state.conn.generation == 2

    assert {:ok, latest, {:output_text_delta, "complete"}} = XaiRealtime.recv(latest, 100)
    assert latest.transport_state.conn.generation == 3
  end

  defp state(reads) do
    clock_key = {__MODULE__, make_ref()}
    Process.put(clock_key, 0)
    ref = make_ref()

    %{
      conn: %{reads: reads, generation: 0, ref: ref, clock_key: clock_key},
      ref: ref,
      ws: struct(Mint.WebSocket),
      pending: [],
      clock_fun: fn -> Process.get(clock_key) end
    }
  end

  defp wire_frame(event) do
    json = Jason.encode!(event)
    <<0x81, byte_size(json), json::binary>>
  end
end
