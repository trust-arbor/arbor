defmodule ConversationKitTest do
  use ExUnit.Case, async: true

  defp fixture(name) do
    Path.expand("../../fixtures/v1/#{name}.json", __DIR__) |> File.read!() |> JSON.decode!()
  end

  defp state(name \\ "conversation") do
    fixture = fixture(name)
    {:ok, state} = ConversationKit.replay(fixture["events"], ConversationKit.new(fixture["id"]))
    state
  end

  defp event(state, kind, data) do
    %{
      "id" => "next-#{state["revision"] + 1}",
      "revision" => state["revision"] + 1,
      "kind" => kind,
      "data" => data
    }
  end

  test "same durable fixture has native rendering data for conversation, tools, approvals and uncertainty" do
    projection = state() |> ConversationKit.project()
    assert projection["revision"] == 11

    assert Enum.map(projection["commands"], & &1["status"]) == [
             "completed",
             "pending",
             "uncertain"
           ]

    assert length(projection["messages"]) == 4

    assert Enum.uniq(Enum.map(projection["blocks"], & &1["type"])) ==
             ~w(message command tool approval)

    assert Enum.all?(projection["blocks"], &(is_binary(&1["id"]) and is_binary(&1["text"])))
    assert [%{"status" => "running"}] = projection["tools"]
    assert [%{"status" => "pending", "protected" => true}] = projection["approvals"]
  end

  test "reconnect and exact replay preserve state and speech descriptions without causing playback" do
    assert state("recovery") == state()
    source = fixture("conversation")
    {head, tail} = Enum.split(source["events"], 6)
    assert {:ok, checkpoint} = ConversationKit.replay(head, ConversationKit.new(source["id"]))
    assert {:ok, resumed} = ConversationKit.replay(tail, checkpoint)
    assert resumed == state()

    assert ConversationKit.project(resumed)["speech"] ==
             ConversationKit.project(state())["speech"]
  end

  test "gap, changed duplicate and reused identity reject rather than advance the cursor" do
    current = state()
    first = hd(current["events"])

    assert {:error, :conflicting_duplicate} =
             ConversationKit.apply(current, put_in(first, ["data", "command_id"], "changed"))

    assert {:error, :revision_gap} = ConversationKit.apply(current, %{first | "revision" => 13})

    assert {:error, :reused_event_id} =
             ConversationKit.apply(current, %{first | "revision" => 12})

    assert current["revision"] == 11
  end

  test "unknown authoritative events and additional fields stop a transactional replay" do
    events = fixture("conversation")["events"]
    unknown = %{"id" => "unknown", "revision" => 12, "kind" => "unrecognized", "data" => %{}}
    assert {:error, :invalid_event} = ConversationKit.replay(events ++ [unknown])
    refute ConversationKit.valid_event?(Map.put(hd(events), "hidden", true))
    refute ConversationKit.valid_event?(put_in(hd(events), ["data", "hidden"], true))
    refute ConversationKit.valid_event?(%{hd(events) | "id" => "trailing\n"})
    refute ConversationKit.valid_event?(%{hd(events) | "revision" => 0})
    refute ConversationKit.valid_event?(%{hd(events) | "data" => []})
  end

  test "terminal outcomes are immutable and completion requires its saved assistant message" do
    current = state()
    cancelled = %{"status" => "cancelled", "output" => nil, "error" => nil}

    assert {:error, :command_not_pending} =
             ConversationKit.apply(
               current,
               event(current, "settled", %{"command_id" => "hello", "outcome" => cancelled})
             )

    completed = %{
      "status" => "completed",
      "output" => %{"message_id" => "missing", "text" => "invented"},
      "error" => nil
    }

    assert {:error, :completion_without_matching_message} =
             ConversationKit.apply(
               current,
               event(current, "settled", %{"command_id" => "research", "outcome" => completed})
             )

    assert {:error, :command_not_pending} =
             ConversationKit.apply(
               current,
               event(current, "message", %{
                 "message" => %{
                   "id" => "late",
                   "role" => "assistant",
                   "text" => "late",
                   "command_id" => "unclear"
                 }
               })
             )
  end

  test "tool and approval lifecycles reduce once and prevent contradictory terminal updates" do
    finished = state("lifecycle")
    assert [%{"status" => "completed"}] = finished["tools"]
    assert [%{"status" => "approved"}] = finished["approvals"]

    assert {:error, :tool_not_running} =
             ConversationKit.apply(
               finished,
               event(finished, "tool_finished", %{
                 "id" => "tool-search",
                 "status" => "failed",
                 "text" => "late"
               })
             )

    assert {:error, :approval_not_pending} =
             ConversationKit.apply(
               finished,
               event(finished, "approval_resolved", %{
                 "id" => "approval-access",
                 "decision" => "denied"
               })
             )
  end

  test "intents are data and never authorize or modify the authoritative state" do
    current = state()

    assert {:ok,
            %{
              "name" => "chat.send",
              "conversation_id" => "shared-demo",
              "input" => %{"text" => "New question"}
            }} = ConversationKit.intent(current, "send", %{"text" => "New question"})

    assert {:ok, %{"name" => "chat.cancel"}} =
             ConversationKit.intent(current, "cancel", %{"command_id" => "research"})

    assert {:ok, %{"name" => "approval.respond"}} =
             ConversationKit.intent(current, "approve", %{
               "approval_id" => "approval-access",
               "decision" => "approved"
             })

    assert {:error, :invalid_intent} = ConversationKit.intent(current, "send", %{"text" => "  "})

    assert {:error, :command_not_pending} =
             ConversationKit.intent(current, "cancel", %{"command_id" => "hello"})

    assert {:error, :approval_not_pending} =
             ConversationKit.intent(state("lifecycle"), "approve", %{
               "approval_id" => "approval-access",
               "decision" => "denied"
             })

    assert current == state()
  end

  test "progress is disposable state and does not become transcript or affect replay" do
    durable = state()

    assert {:ok, %{"research" => "Drafting..."}} =
             ConversationKit.progress(%{}, %{"command_id" => "research", "text" => "Drafting..."})

    assert {:error, :invalid_progress} =
             ConversationKit.progress(%{}, %{
               "command_id" => "research",
               "text" => "Drafting...",
               "revision" => 12
             })

    assert durable["revision"] == 11
    refute Enum.any?(durable["messages"], &(&1["text"] == "Drafting..."))
  end

  test "speech includes completed assistant content and escalates protected approvals without reading them" do
    speech = state() |> ConversationKit.project() |> Map.fetch!("speech")

    assert [
             %{"type" => "utterance", "utterance_id" => "hello.assistant"},
             %{"type" => "screen_required", "interaction_id" => "approval-access"}
           ] = speech

    refute Enum.any?(speech, &String.contains?(&1["text"], "private planning"))
    finished = state("lifecycle") |> ConversationKit.project() |> Map.fetch!("speech")
    assert Enum.all?(finished, &(&1["type"] == "utterance"))
    assert length(finished) == 2
  end

  test "UTF-8 byte limits reject oversized strings even when character count is small" do
    assert {:error, :invalid_intent} =
             ConversationKit.intent(ConversationKit.new(), "send", %{
               "text" => String.duplicate("界", 6000)
             })

    assert {:error, :invalid_intent} =
             ConversationKit.intent(ConversationKit.new(), "send", %{"text" => <<255>>})

    assert {:ok, _} =
             ConversationKit.intent(ConversationKit.new(), "send", %{
               "text" => String.duplicate("a", 16_000)
             })
  end

  test "terminal commands suppress stale approval controls and speech without inventing cleanup evidence" do
    for terminal <- ~w(cancelled failed uncertain) do
      current = state()

      error =
        if terminal == "cancelled",
          do: nil,
          else: %{
            "code" => "work_stopped",
            "message" => "Result unavailable",
            "retryable" => false
          }

      settled =
        event(current, "settled", %{
          "command_id" => "research",
          "outcome" => %{"status" => terminal, "output" => nil, "error" => error}
        })

      assert {:ok, terminal_state} = ConversationKit.apply(current, settled)
      projection = ConversationKit.project(terminal_state)
      assert [%{"status" => "pending"}] = terminal_state["approvals"]
      assert [%{"status" => "running"}] = terminal_state["tools"]

      assert [
               %{
                 "status" => "unresolved",
                 "authoritative_status" => "pending",
                 "actionable" => false
               }
             ] = projection["approvals"]

      assert [%{"status" => "unresolved", "authoritative_status" => "running", "active" => false}] =
               projection["tools"]

      refute Enum.any?(projection["speech"], &(&1["type"] == "screen_required"))

      assert {:error, :approval_not_pending} =
               ConversationKit.intent(terminal_state, "approve", %{
                 "approval_id" => "approval-access",
                 "decision" => "approved"
               })
    end
  end

  test "Elixir port reproduces the retained DASP experiment's 43 updates and 11 terminal command states" do
    current = state("dasp-import")
    expected = fixture("dasp-expected")

    commands =
      Map.new(current["commands"], fn {id, value} ->
        {id, Map.take(value, ~w(name status outcome))}
      end)

    assert %{"messages" => current["messages"], "commands" => commands} == expected["state"]
    assert current["revision"] == expected["cursor"]
    assert current["revision"] == 43
    assert map_size(commands) == 11
    assert current["commands"]["opaque-crash"]["status"] == "uncertain"
  end

  test "the schema and fixture inventory cover exactly the known authoritative event kinds" do
    schema = Path.expand("../priv/event.schema.json", __DIR__) |> File.read!() |> JSON.decode!()
    schema_kinds = Enum.map(schema["oneOf"], & &1["properties"]["kind"]["const"]) |> Enum.sort()

    manifest =
      Path.expand("../../fixtures/manifest.json", __DIR__) |> File.read!() |> JSON.decode!()

    assert schema_kinds == Enum.sort(manifest["event_kinds"])
    assert Enum.all?(fixture("lifecycle")["events"], &ConversationKit.valid_event?/1)
    assert Enum.all?(schema["oneOf"], &(&1["additionalProperties"] == false))
  end
end
