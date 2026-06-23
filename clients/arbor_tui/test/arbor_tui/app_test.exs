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
      turn: :idle,
      pending_approvals: [],
      auto_approve: MapSet.new()
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

  describe "HITL approvals" do
    defp pending(state \\ %{}) do
      model(
        Map.merge(
          %{pending_approvals: [%{proposal_id: "p1", tool: "find_tools", args: %{}}]},
          state
        )
      )
    end

    test "y/n/a are intercepted only while an approval is pending" do
      # idle: keys type into the input
      assert App.event_to_msg(%Event.Key{char: "y"}, model()) == {:msg, {:char, "y"}}

      # pending: y/n/a decide, other keys (and enter) are swallowed
      assert App.event_to_msg(%Event.Key{char: "y"}, pending()) == {:msg, {:approval, :approve}}
      assert App.event_to_msg(%Event.Key{char: "n"}, pending()) == {:msg, {:approval, :deny}}
      assert App.event_to_msg(%Event.Key{char: "a"}, pending()) == {:msg, {:approval, :always}}
      assert App.event_to_msg(%Event.Key{char: "z"}, pending()) == :ignore
      assert App.event_to_msg(%Event.Key{key: :enter}, pending()) == :ignore

      # Ctrl+C still quits mid-approval
      assert App.event_to_msg(%Event.Key{key: :c, modifiers: [:ctrl]}, pending()) == {:msg, :quit}
    end

    test "approve pops the head and notes it" do
      s =
        pending(%{
          pending_approvals: [
            %{proposal_id: "p1", tool: "find_tools", args: %{}},
            %{proposal_id: "p2", tool: "shell", args: %{}}
          ]
        })

      s = up({:approval, :approve}, s)
      assert [%{proposal_id: "p2"}] = s.pending_approvals
      assert List.last(s.messages).role == :system
    end

    test "always-allow remembers the tool and auto-approves future requests" do
      s = up({:approval, :always}, pending())
      assert MapSet.member?(s.auto_approve, "find_tools")
      assert s.pending_approvals == []

      # a later request for the same tool is auto-approved, not queued
      s =
        up(
          {:server_event,
           {:approval_request, %{proposal_id: "p9", tool: "find_tools", args: %{}}}},
          s
        )

      assert s.pending_approvals == []
      assert Enum.any?(s.messages, &(&1.text =~ "auto-approved"))
    end

    test "approval_request queues; approval_resolved removes" do
      s =
        up(
          {:server_event,
           {:approval_request, %{proposal_id: "p1", tool: "shell", args: %{"cmd" => "ls"}}}},
          model()
        )

      assert [%{proposal_id: "p1", tool: "shell"}] = s.pending_approvals

      s = up({:server_event, {:approval_resolved, %{proposal_id: "p1", status: "approved"}}}, s)
      assert s.pending_approvals == []
    end
  end
end
