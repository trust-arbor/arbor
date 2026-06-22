defmodule ArborTui.AppTest do
  use ExUnit.Case, async: true

  alias ArborTui.App
  alias TermUI.Event

  # Build a model directly (init/1 spawns the WS client; the reducers below are
  # what we want to exercise, and they're pure).
  defp model(overrides \\ %{}) do
    base = %{
      ws: nil,
      identity_id: "agent_me",
      agent_id: "agent_target",
      gateway_url: "ws://localhost:4000",
      status: :connecting,
      status_detail: nil,
      engagement_id: nil,
      input: "",
      messages: [],
      streaming: nil,
      turn: :idle
    }

    Map.merge(base, overrides)
  end

  defp up(msg, state), do: elem(App.update(msg, state), 0)

  describe "event_to_msg/2" do
    test "Ctrl+C quits; bare 'c' types" do
      assert App.event_to_msg(%Event.Key{key: :c, modifiers: [:ctrl]}, model()) == {:msg, :quit}
      assert App.event_to_msg(%Event.Key{key: :c, modifiers: []}, model()) == {:msg, {:char, "c"}}
    end

    test "enter submits, backspace, printable chars" do
      assert App.event_to_msg(%Event.Key{key: :enter}, model()) == {:msg, :submit}
      assert App.event_to_msg(%Event.Key{key: :backspace}, model()) == {:msg, :backspace}

      assert App.event_to_msg(%Event.Key{key: :x, char: "x"}, model()) == {:msg, {:char, "x"}}
    end
  end

  describe "input editing" do
    test "typing and backspace edit the buffer" do
      s = model() |> then(&up({:char, "h"}, &1)) |> then(&up({:char, "i"}, &1))
      assert s.input == "hi"
      assert up(:backspace, s).input == "h"
      assert up(:clear_input, s).input == ""
    end
  end

  describe "submit" do
    test "appends the user message, clears input, marks the turn thinking" do
      s = model(%{input: "hello"}) |> then(&up(:submit, &1))
      assert s.input == ""
      assert s.turn == :thinking
      assert List.last(s.messages) == %{role: :you, text: "hello"}
    end

    test "empty submit is a no-op" do
      assert up(:submit, model()).messages == []
    end
  end

  describe "server events" do
    test "engagement loads the transcript" do
      ev =
        {:server_event,
         {:engagement, %{id: "eng_1", transcript: [%{"role" => "user", "content" => "earlier"}]}}}

      s = up(ev, model())
      assert s.engagement_id == "eng_1"
      assert s.messages == [%{role: :you, text: "earlier"}]
    end

    test "delta accumulates streaming; message finalizes and clears it" do
      s = model(%{turn: :thinking})
      s = up({:server_event, {:delta, "Hel"}}, s)
      s = up({:server_event, {:delta, "lo"}}, s)
      assert s.streaming == "Hello"

      s = up({:server_event, {:message, %{"role" => "assistant", "content" => "Hello"}}}, s)
      assert s.streaming == nil
      assert List.last(s.messages) == %{role: :agent, text: "Hello"}

      assert up({:server_event, {:turn_complete, %{}}}, s).turn == :idle
    end

    test "notification interleaves as the 💭 channel" do
      s = up({:server_event, {:notification, %{text: "audit done", kind: "thought"}}}, model())
      assert List.last(s.messages) == %{role: :notification, text: "audit done"}
    end

    test "error surfaces and resets the turn" do
      s = up({:server_event, {:error, "unauthorized"}}, model(%{turn: :thinking}))
      assert s.turn == :idle
      assert List.last(s.messages) == %{role: :system, text: "error: unauthorized"}
    end
  end

  describe "connection status" do
    test "ws_status updates the model" do
      s = up({:ws_status, :connected, nil}, model())
      assert s.status == :connected

      s = up({:ws_status, :error, "econnrefused"}, s)
      assert s.status == :error
      assert s.status_detail == "econnrefused"
    end
  end

  describe "quit" do
    test "returns a quit command" do
      assert {_state, [%TermUI.Command{}]} = App.update(:quit, model())
    end
  end
end
