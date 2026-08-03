defmodule Arbor.Voice.Session.TurnCoreTest do
  @moduledoc """
  Pure TurnCore event-reduction proofs for VP-04E1 (VOICE-3/5/8 partial).
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.Session.TurnCore

  describe "new/0" do
    test "starts with empty accumulator and empty seen-id set" do
      state = TurnCore.new()
      assert state.text_acc == ""
      assert MapSet.size(state.seen_tool_ids) == 0
    end
  end

  describe "text delta and terminal reduction" do
    @tag spec: "VOICE-3"
    test "accumulates deltas and uses blank-terminal fallback" do
      state = TurnCore.new()

      assert {:continue, s1} = TurnCore.reduce(state, {:output_text_delta, "hel"})
      assert {:continue, s2} = TurnCore.reduce(s1, {:output_text_delta, "lo"})
      assert s2.text_acc == "hello"

      assert {:done, "hello"} = TurnCore.reduce(s2, {:turn_done, %{text: ""}})
      assert {:done, "hello"} = TurnCore.reduce(s2, {:turn_done, %{text: "   "}})
    end

    @tag spec: "VOICE-3"
    test "nonblank terminal text is authoritative over deltas" do
      state = TurnCore.new()
      assert {:continue, s1} = TurnCore.reduce(state, {:output_text_delta, "partial"})
      assert {:done, "final answer"} = TurnCore.reduce(s1, {:turn_done, %{text: "final answer"}})
    end

    @tag spec: "VOICE-5"
    test "oversized delta or terminal fails closed" do
      huge = String.duplicate("a", TurnCore.max_text_bytes() + 1)
      state = TurnCore.new()

      assert {:error, :protocol_error} = TurnCore.reduce(state, {:output_text_delta, huge})
      assert {:error, :protocol_error} = TurnCore.reduce(state, {:turn_done, %{text: huge}})

      almost = String.duplicate("b", TurnCore.max_text_bytes() - 1)
      assert {:continue, s1} = TurnCore.reduce(state, {:output_text_delta, almost})
      assert {:error, :protocol_error} = TurnCore.reduce(s1, {:output_text_delta, "xx"})
    end

    @tag spec: "VOICE-5"
    test "invalid UTF-8 delta or terminal fails before trim or concatenation" do
      state = TurnCore.new()
      bad = <<0xFF, 0xFE>>

      assert {:error, :protocol_error} = TurnCore.reduce(state, {:output_text_delta, bad})
      assert {:error, :protocol_error} = TurnCore.reduce(state, {:turn_done, %{text: bad}})

      # Valid prefix then invalid delta must not corrupt the accumulator.
      assert {:continue, s1} = TurnCore.reduce(state, {:output_text_delta, "ok"})
      assert {:error, :protocol_error} = TurnCore.reduce(s1, {:output_text_delta, bad})
      assert s1.text_acc == "ok"
    end

    @tag spec: "VOICE-3,VOICE-5"
    test "blank terminal with blank accumulator is protocol_error not empty done" do
      state = TurnCore.new()

      assert {:error, :protocol_error} = TurnCore.reduce(state, {:turn_done, %{text: ""}})
      assert {:error, :protocol_error} = TurnCore.reduce(state, {:turn_done, %{text: "   "}})

      # Whitespace-only deltas leave a blank fallback under trim.
      assert {:continue, s1} = TurnCore.reduce(state, {:output_text_delta, "  "})
      assert {:error, :protocol_error} = TurnCore.reduce(s1, {:turn_done, %{text: ""}})
    end

    @tag spec: "VOICE-5"
    test "malformed core state fails closed without raising" do
      bad_seen = %{text_acc: "hello", seen_tool_ids: MapSet.new() |> MapSet.to_list()}
      assert is_list(bad_seen.seen_tool_ids)

      assert {:error, :protocol_error} =
               TurnCore.reduce(bad_seen, {:output_text_delta, "x"})

      assert {:error, :protocol_error} =
               TurnCore.reduce(%{text_acc: "x", seen_tool_ids: %{}}, {:turn_done, %{text: "y"}})

      assert {:error, :protocol_error} =
               TurnCore.reduce(%{text_acc: "x", seen_tool_ids: nil}, {:tool_call, %{}})

      assert {:error, :protocol_error} =
               TurnCore.reduce(
                 %{text_acc: <<0xFF>>, seen_tool_ids: MapSet.new()},
                 {:turn_done, %{text: "y"}}
               )

      assert {:error, :protocol_error} = TurnCore.reduce(:not_a_state, {:turn_done, %{text: "y"}})
      assert {:error, :protocol_error} = TurnCore.reduce(%{}, {:output_text_delta, "x"})
    end
  end

  describe "benign input events" do
    @tag spec: "VOICE-5"
    test "ignores validated input_transcript and output_audio without retaining payloads" do
      state = TurnCore.new()

      assert {:continue, s1} = TurnCore.reduce(state, {:input_transcript, "user said hi"})
      assert s1 == state
      assert s1.text_acc == ""

      assert {:continue, s2} = TurnCore.reduce(s1, {:output_audio, <<1, 2, 3, 4>>})
      assert s2 == s1
      refute Map.has_key?(s2, :audio)
    end

    @tag spec: "VOICE-5"
    test "rejects invalid input_transcript" do
      state = TurnCore.new()
      bad = <<0xFF, 0xFE>>
      assert {:error, :protocol_error} = TurnCore.reduce(state, {:input_transcript, bad})

      huge = String.duplicate("x", TurnCore.max_text_bytes() + 1)
      assert {:error, :protocol_error} = TurnCore.reduce(state, {:input_transcript, huge})
    end

    @tag spec: "VOICE-5"
    test "security regression: oversized output_audio is protocol_error and not retained" do
      state = TurnCore.new()
      at_cap = :binary.copy(<<0>>, TurnCore.max_audio_bytes())
      over = :binary.copy(<<0>>, TurnCore.max_audio_bytes() + 1)

      assert {:continue, s1} = TurnCore.reduce(state, {:output_audio, at_cap})
      assert s1 == state
      refute Map.has_key?(s1, :audio)

      assert {:error, :protocol_error} = TurnCore.reduce(state, {:output_audio, over})

      assert {:error, :protocol_error} =
               TurnCore.reduce(state, {:output_audio, :binary.copy(<<1>>, 100_000)})
    end
  end

  describe "tool call handling" do
    @tag spec: "VOICE-8"
    test "well-formed tool call returns admit_tool and marks id; duplicates continue" do
      state = TurnCore.new()
      call = %{id: "call_1", name: "consult_agent", arguments: %{"q" => "hi"}}

      assert {:admit_tool, s1, admitted} = TurnCore.reduce(state, {:tool_call, call})
      assert admitted == %{id: "call_1", name: "consult_agent", arguments: %{"q" => "hi"}}
      assert MapSet.member?(s1.seen_tool_ids, "call_1")
      assert s1.tool_wave == true

      assert {:continue, s2} = TurnCore.reduce(s1, {:tool_call, call})
      assert s2.seen_tool_ids == s1.seen_tool_ids
    end

    @tag spec: "VOICE-8"
    test "tool-bearing blank turn_done resets cycle independent of settlement" do
      state = TurnCore.new()
      call = %{id: "c1", name: "x", arguments: %{}}

      assert {:admit_tool, s1, _} = TurnCore.reduce(state, {:tool_call, call})
      assert {:continue, s2} = TurnCore.reduce(s1, {:output_text_delta, "pre-tool"})
      assert s2.text_acc == "pre-tool"

      # Blank done clears pre-tool text even if shell still has pending work.
      assert {:cycle_reset, s3} = TurnCore.reduce(s2, {:turn_done, %{text: ""}})
      assert s3.tool_wave == false
      assert s3.text_acc == ""
    end

    @tag spec: "VOICE-8"
    test "tool-bearing nonblank turn_done is intermediate cycle_reset; discards text" do
      state = TurnCore.new()
      call = %{id: "c1", name: "x", arguments: %{}}

      assert {:admit_tool, s1, _} = TurnCore.reduce(state, {:tool_call, call})
      assert {:continue, s2} = TurnCore.reduce(s1, {:output_text_delta, "pre-tool-leak"})
      # Nonblank intermediate must NOT complete — only later tool_wave=false terminal.
      assert {:cycle_reset, s3} = TurnCore.reduce(s2, {:turn_done, %{text: "not final"}})
      assert s3.tool_wave == false
      assert s3.text_acc == ""

      # Post-wave terminal can complete.
      assert {:done, "real final"} = TurnCore.reduce(s3, {:turn_done, %{text: "real final"}})
    end

    @tag spec: "VOICE-8"
    test "settlement-before-intermediate-done race: cycle_reset then later done" do
      state = TurnCore.new()
      call = %{id: "c1", name: "x", arguments: %{}}

      assert {:admit_tool, s1, _} = TurnCore.reduce(state, {:tool_call, call})
      # Simulate: owners already settled (shell pending empty) before response.done.
      assert {:cycle_reset, s2} = TurnCore.reduce(s1, {:turn_done, %{text: ""}})
      assert s2.tool_wave == false
      assert {:done, "post-tool"} = TurnCore.reduce(s2, {:turn_done, %{text: "post-tool"}})
    end

    @tag spec: "VOICE-8"
    test "malformed tool calls fail closed" do
      state = TurnCore.new()

      assert {:error, :protocol_error} =
               TurnCore.reduce(state, {:tool_call, %{name: "x", arguments: %{}}})

      assert {:error, :protocol_error} =
               TurnCore.reduce(state, {:tool_call, %{id: "  ", name: "x", arguments: %{}}})

      assert {:error, :protocol_error} =
               TurnCore.reduce(state, {:tool_call, %{id: "c1", name: "", arguments: %{}}})

      assert {:error, :protocol_error} =
               TurnCore.reduce(state, {:tool_call, %{id: "c1", name: "x", arguments: "nope"}})
    end

    @tag spec: "VOICE-8"
    test "security regression: non-JSON or bounded arguments fail closed without admit" do
      state = TurnCore.new()
      huge = String.duplicate("x", TurnCore.max_args_encoded_bytes() + 1)

      assert {:error, :protocol_error} =
               TurnCore.reduce(
                 state,
                 {:tool_call, %{id: "c1", name: "x", arguments: %{"b" => huge}}}
               )

      deep =
        Enum.reduce(1..(TurnCore.max_args_depth() + 2), %{"v" => 1}, fn _, acc ->
          %{"n" => acc}
        end)

      assert {:error, :protocol_error} =
               TurnCore.reduce(state, {:tool_call, %{id: "c2", name: "x", arguments: deep}})

      assert {:error, :protocol_error} =
               TurnCore.reduce(
                 state,
                 {:tool_call, %{id: "c3", name: "x", arguments: %{"p" => self()}}}
               )

      assert {:error, :protocol_error} =
               TurnCore.reduce(
                 state,
                 {:tool_call, %{id: "c4", name: "x", arguments: %{atom_key: 1}}}
               )

      assert {:error, :protocol_error} =
               TurnCore.reduce(
                 state,
                 {:tool_call, %{id: "c5", name: "x", arguments: %{"bad" => [1 | 2]}}}
               )

      # Id must not be marked on failed admission.
      assert MapSet.size(state.seen_tool_ids) == 0
    end

    @tag spec: "VOICE-8"
    test "no_tools_installed_output is deterministic JSON with code" do
      out = TurnCore.no_tools_installed_output()
      assert is_binary(out)
      assert {:ok, %{"code" => "no_tools_installed"}} = Jason.decode(out)
    end
  end

  describe "backend error and malformed events" do
    @tag spec: "VOICE-5"
    test "backend error event and unknown shapes fail closed" do
      state = TurnCore.new()
      assert {:error, :protocol_error} = TurnCore.reduce(state, {:error, :connection_dropped})
      assert {:error, :protocol_error} = TurnCore.reduce(state, :not_an_event)
      assert {:error, :protocol_error} = TurnCore.reduce(state, {:turn_done, %{}})
    end
  end
end
