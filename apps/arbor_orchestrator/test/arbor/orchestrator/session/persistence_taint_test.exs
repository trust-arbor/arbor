defmodule Arbor.Orchestrator.Session.PersistenceTaintTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Contracts.Session.AssistantMessage
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Orchestrator.Session.Persistence
  alias Arbor.Orchestrator.Session.Persistence.Core

  @sent_at ~U[2026-08-05 12:00:00.000000Z]
  @completed_at ~U[2026-08-05 12:00:03.000000Z]

  describe "turn entry construction" do
    test "binds exact final payloads to monotonic labels from every exact context alias" do
      tool_calls = [
        %{"id" => "tool-1", "name" => "lookup", "input" => %{"key" => "value"}}
      ]

      input_taint = taint("session_input", :untrusted, :internal, 3, :corroborated)
      query_taint = taint("session_query", :derived, :confidential, 1, :plausible)
      response_taint = taint("session_response", :derived, :internal, 7, :plausible)
      raw_output_taint = taint("last_response", :derived, :public, 5, :plausible)
      tools_taint = taint("session_tool_calls", :untrusted, :restricted, 1, :unverified)

      run_result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "user text",
          "session.query" => "user text",
          "session.response" => "assistant text",
          "last_response" => "assistant text",
          "session.tool_calls" => tool_calls
        },
        taint: %{
          "session.input" => input_taint,
          "session.query" => query_taint,
          "session.response" => response_taint,
          "last_response" => raw_output_taint,
          "session.tool_calls" => tools_taint
        }
      }

      assistant = %AssistantMessage{
        content: "assistant text",
        tool_calls: tool_calls,
        model: "model-c6a",
        finish_reason: :stop,
        started_at: @sent_at,
        completed_at: @completed_at
      }

      assert {:ok, [user_entry, assistant_entry]} =
               build_entries(
                 %{
                   "role" => "user",
                   "content" => "user text",
                   "metadata" => %{
                     "engagement_id" => "forged-engagement",
                     "taint" => %{"caller" => "forged"}
                   }
                 },
                 assistant,
                 run_result
               )

      assert [user_entry.entry_type, assistant_entry.entry_type] == ["user", "assistant"]
      assert user_entry.timestamp == @sent_at
      assert assistant_entry.timestamp == @completed_at
      assert user_entry.metadata["engagement_id"] == "engagement-c6a"
      assert assistant_entry.metadata["engagement_id"] == "engagement-c6a"
      refute user_entry.metadata["engagement_id"] == "forged-engagement"

      assert {:ok, user_envelope} =
               TaintEnvelope.verify(user_entry.metadata["taint"], user_entry.content)

      assert {:ok, assistant_envelope} =
               TaintEnvelope.verify(
                 assistant_entry.metadata["taint"],
                 assistant_entry.content
               )

      assert {:error, :payload_mismatch} =
               TaintEnvelope.verify(
                 user_entry.metadata["taint"],
                 [%{"type" => "text", "text" => "changed"}]
               )

      assert source_labels(user_envelope.taint) ==
               MapSet.new(["session_input", "session_query"])

      assert source_labels(assistant_envelope.taint) ==
               MapSet.new([
                 "last_response",
                 "session_input",
                 "session_query",
                 "session_response",
                 "session_tool_calls"
               ])

      assert monotonic_at_least?(assistant_envelope.taint, user_envelope.taint)

      assert assistant_entry.content == [
               %{"type" => "text", "text" => "assistant text"},
               %{
                 "type" => "tool_use",
                 "id" => "tool-1",
                 "name" => "lookup",
                 "input" => %{"key" => "value"}
               }
             ]
    end

    test "uses conservative labels when exact evidence is absent or malformed" do
      response_taint = taint("response", :derived, :internal, 0, :plausible)

      missing_user_result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "different user payload",
          "session.response" => "assistant text"
        },
        taint: %{
          "session.input" => taint("wrong_payload", :trusted, :public, 255, :verified),
          "session.response" => response_taint
        }
      }

      assert {:ok, [missing_user, _assistant]} =
               build_entries(default_user(), default_assistant(), missing_user_result)

      assert {:ok, missing_envelope} =
               TaintEnvelope.verify(missing_user.metadata["taint"], missing_user.content)

      assert missing_envelope.taint == TaintEnvelope.missing_fallback()

      malformed_result = %{
        final_outcome: %{status: :partial_success},
        context: %{
          "session.input" => "user text",
          "session.response" => "assistant text"
        },
        taint: %{
          "session.input" => taint("input", :untrusted, :internal, 0, :unverified),
          "session.response" => %{"malformed" => true}
        }
      }

      assert {:ok, [_user, malformed_assistant]} =
               build_entries(default_user(), default_assistant(), malformed_result)

      assert {:ok, malformed_envelope} =
               TaintEnvelope.verify(
                 malformed_assistant.metadata["taint"],
                 malformed_assistant.content
               )

      assert malformed_envelope.taint == TaintEnvelope.invalid_fallback()
    end

    test "partial turns join trusted evidence without weakening the source-owned baseline" do
      forged_input = taint("forged_trusted_input", :trusted, :public, 255, :verified)
      forged_output = taint("forged_trusted_output", :trusted, :public, 255, :verified)

      forged_result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "user text",
          "session.response" => "partial answer"
        },
        taint: %{
          "session.input" => forged_input,
          "session.response" => forged_output
        }
      }

      messages = [
        AssistantMessage.interrupted("partial answer", :timeout, @sent_at,
          completed_at: @completed_at
        ),
        AssistantMessage.cancelled("partial answer", @sent_at, completed_at: @completed_at)
      ]

      Enum.each(messages, fn assistant ->
        assert {:ok, [user_entry, assistant_entry]} =
                 build_entries(default_user(), assistant, forged_result)

        assert {:ok, user_envelope} =
                 TaintEnvelope.verify(user_entry.metadata["taint"], user_entry.content)

        assert {:ok, assistant_envelope} =
                 TaintEnvelope.verify(
                   assistant_entry.metadata["taint"],
                   assistant_entry.content
                 )

        assert user_envelope.taint.level == :untrusted
        assert user_envelope.taint.sensitivity == :restricted
        assert user_envelope.taint.sanitizations == 0
        assert user_envelope.taint.confidence == :unverified

        assert source_labels(user_envelope.taint) ==
                 MapSet.new(["forged_trusted_input", "session_partial_user_input"])

        assert assistant_envelope.taint.level == :untrusted
        assert assistant_envelope.taint.sensitivity == :restricted
        assert assistant_envelope.taint.sanitizations == 0
        assert assistant_envelope.taint.confidence == :unverified

        assert source_labels(assistant_envelope.taint) ==
                 MapSet.new([
                   "forged_trusted_input",
                   "forged_trusted_output",
                   "session_partial_llm_output",
                   "session_partial_user_input"
                 ])

        assert assistant_entry.metadata["status"] == to_string(assistant.status)
      end)
    end

    @tag :security_regression
    test "security regression: hostile partial input and output remain hostile" do
      hostile_input = taint("hostile_partial_input", :hostile, :internal, 7, :verified)

      hostile_output =
        taint("hostile_partial_output", :hostile, :confidential, 3, :corroborated)

      hostile_result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "user text",
          "session.response" => "partial answer"
        },
        taint: %{
          "session.input" => hostile_input,
          "session.response" => hostile_output
        }
      }

      messages = [
        AssistantMessage.interrupted("partial answer", :timeout, @sent_at,
          completed_at: @completed_at
        ),
        AssistantMessage.cancelled("partial answer", @sent_at, completed_at: @completed_at)
      ]

      Enum.each(messages, fn assistant ->
        assert {:ok, [user_entry, assistant_entry]} =
                 build_entries(default_user(), assistant, hostile_result)

        user_taint = verified_entry_taint(user_entry)
        assistant_taint = verified_entry_taint(assistant_entry)

        assert user_taint.level == :hostile
        assert user_taint.sensitivity == :restricted

        assert source_labels(user_taint) ==
                 MapSet.new(["hostile_partial_input", "session_partial_user_input"])

        assert assistant_taint.level == :hostile
        assert assistant_taint.sensitivity == :restricted

        assert source_labels(assistant_taint) ==
                 MapSet.new([
                   "hostile_partial_input",
                   "hostile_partial_output",
                   "session_partial_llm_output",
                   "session_partial_user_input"
                 ])
      end)
    end

    test "partial turns use invalid fallback for malformed exact evidence" do
      trusted_input = taint("valid_partial_input", :trusted, :public, 255, :verified)
      trusted_output = taint("valid_partial_output", :trusted, :public, 255, :verified)

      assistant =
        AssistantMessage.interrupted("partial answer", :timeout, @sent_at,
          completed_at: @completed_at
        )

      malformed_input_result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "user text",
          "session.response" => "partial answer"
        },
        taint: %{
          "session.input" => %{"malformed" => true},
          "session.response" => trusted_output
        }
      }

      assert {:ok, [invalid_user, invalid_assistant]} =
               build_entries(default_user(), assistant, malformed_input_result)

      assert verified_entry_taint(invalid_user) == TaintEnvelope.invalid_fallback()
      assert verified_entry_taint(invalid_assistant) == TaintEnvelope.invalid_fallback()

      malformed_output_result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "user text",
          "session.response" => "partial answer"
        },
        taint: %{
          "session.input" => trusted_input,
          "session.response" => %{"malformed" => true}
        }
      }

      assert {:ok, [valid_user, invalid_assistant]} =
               build_entries(default_user(), assistant, malformed_output_result)

      assert verified_entry_taint(valid_user).level == :untrusted
      assert verified_entry_taint(invalid_assistant) == TaintEnvelope.invalid_fallback()
    end
  end

  describe "persistence shell" do
    test "the turn builder carries admitted Engine taint into the atomic batch" do
      parent = self()
      input_taint = taint("wired_input", :untrusted, :internal, 0, :unverified)
      output_taint = taint("wired_output", :derived, :internal, 0, :plausible)

      state = %Arbor.Orchestrator.Session{
        session_id: "tenant-session-builder",
        agent_id: "agent-builder-owner",
        current_engagement_id: "engagement-c6a",
        adapters: %{
          ensure_session: fn session_id, agent_id, [] ->
            {:ok, %{id: "builder-session-uuid", session_id: session_id, agent_id: agent_id}}
          end,
          append_session_entries: fn session_uuid, entries ->
            send(parent, {:builder_batch, session_uuid, entries})
            {:ok, length(entries)}
          end
        }
      }

      result = %{
        final_outcome: %{status: :success},
        context: %{
          "session.input" => "builder user",
          "session.query" => "builder user",
          "session.response" => "builder assistant",
          "last_response" => "builder assistant"
        },
        taint: %{
          "session.input" => input_taint,
          "session.query" => input_taint,
          "session.response" => output_taint,
          "last_response" => output_taint
        }
      }

      updated = Builders.apply_turn_result(state, "builder user", result)
      assert updated.turn_count == 1

      assert_receive {:builder_batch, "builder-session-uuid", [user_entry, assistant_entry]},
                     1_000

      assert {:ok, user_envelope} =
               TaintEnvelope.verify(user_entry.metadata["taint"], user_entry.content)

      assert {:ok, assistant_envelope} =
               TaintEnvelope.verify(
                 assistant_entry.metadata["taint"],
                 assistant_entry.content
               )

      assert source_labels(user_envelope.taint) == MapSet.new(["wired_input"])

      assert source_labels(assistant_envelope.taint) ==
               MapSet.new(["wired_input", "wired_output"])
    end

    test "preserves session ownership and refuses to append after an owner mismatch" do
      parent = self()

      state = %{
        session_id: "tenant-session-owned",
        agent_id: "agent-requesting-owner",
        current_engagement_id: "engagement-c6a",
        turn_count: 0,
        messages: [],
        adapters: %{
          ensure_session: fn session_id, agent_id, opts ->
            send(parent, {:ensure_session, session_id, agent_id, opts})
            {:error, :session_owner_mismatch}
          end,
          append_session_entries: fn _session_uuid, _entries ->
            send(parent, :unexpected_append)
            {:ok, 2}
          end
        }
      }

      assert {:ok, task} =
               Persistence.persist_turn_entries(
                 state,
                 default_user(),
                 default_assistant(),
                 %{},
                 user_sent_at: @sent_at,
                 assistant_completed_at: @completed_at
               )

      monitor = Process.monitor(task)

      assert_receive {:ensure_session, "tenant-session-owned", "agent-requesting-owner", []},
                     1_000

      assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, 1_000
      refute_received :unexpected_append
    end
  end

  describe "engagement transcript restore" do
    test "uses the public filtered projection and retains metadata and label fields in order" do
      parent = self()
      verified = taint("verified_restore", :untrusted, :confidential, 0, :plausible)

      rows = [
        %{
          role: :user,
          content: "restored user",
          metadata: %{"engagement_id" => "engagement-c6a", "row" => 1},
          taint: verified,
          taint_status: :verified
        },
        %{
          role: :assistant,
          content: "restored assistant",
          metadata: %{"engagement_id" => "engagement-c6a", "row" => 2},
          taint: TaintEnvelope.missing_fallback(),
          taint_status: :legacy_unlabeled
        },
        %{
          role: :assistant,
          content: "malformed label",
          metadata: %{"engagement_id" => "engagement-c6a", "row" => 3},
          taint: %{"malformed" => true},
          taint_status: :verified
        },
        %{
          role: :user,
          content: "missing label",
          metadata: %{"engagement_id" => "engagement-c6a", "row" => 4}
        }
      ]

      loader = fn session_id, opts ->
        send(parent, {:load_recent_session_messages, session_id, opts})
        rows
      end

      state = %{
        session_id: "tenant-session-restore",
        adapters: %{load_recent_session_messages: loader}
      }

      assert restored =
               Persistence.load_engagement_transcript(state, "engagement-c6a")

      assert_receive {:load_recent_session_messages, "tenant-session-restore",
                      [engagement_id: "engagement-c6a", limit: 1_000]}

      assert Enum.map(restored, & &1["content"]) == [
               "restored user",
               "restored assistant",
               "malformed label",
               "missing label"
             ]

      assert Enum.map(restored, & &1["role"]) == [
               "user",
               "assistant",
               "assistant",
               "user"
             ]

      assert Enum.at(restored, 0)["metadata"] ==
               %{"engagement_id" => "engagement-c6a", "row" => 1}

      assert Enum.at(restored, 0)["taint"] == verified
      assert Enum.at(restored, 0)["taint_status"] == :verified
      assert Enum.at(restored, 1)["taint"] == TaintEnvelope.missing_fallback()
      assert Enum.at(restored, 1)["taint_status"] == :legacy_unlabeled
      assert Enum.at(restored, 2)["taint"] == TaintEnvelope.invalid_fallback()
      assert Enum.at(restored, 2)["taint_status"] == :invalid_durable_provenance
      assert Enum.at(restored, 3)["taint"] == TaintEnvelope.missing_fallback()
      assert Enum.at(restored, 3)["taint_status"] == :legacy_unlabeled

      Enum.each(restored, fn message ->
        refute message["content"] =~ "taint"
        refute message["content"] =~ "provenance"
      end)
    end

    test "restores more than 50 filtered rows in deterministic engagement order" do
      parent = self()

      rows =
        Enum.flat_map(1..75, fn ordinal ->
          [
            restored_row("engagement-c6a", ordinal),
            restored_row("other-engagement", ordinal)
          ]
        end)

      loader = fn session_id, opts ->
        send(parent, {:load_many_session_messages, session_id, opts})
        engagement_id = Keyword.fetch!(opts, :engagement_id)
        limit = Keyword.get(opts, :limit, 50)

        rows
        |> Enum.filter(&(get_in(&1, [:metadata, "engagement_id"]) == engagement_id))
        |> Enum.take(-limit)
      end

      state = %{
        session_id: "tenant-session-many",
        adapters: %{load_recent_session_messages: loader}
      }

      restored = Persistence.load_engagement_transcript(state, "engagement-c6a")

      assert_receive {:load_many_session_messages, "tenant-session-many",
                      [engagement_id: "engagement-c6a", limit: 1_000]}

      assert length(restored) == 75

      assert Enum.map(restored, & &1["content"]) ==
               Enum.map(1..75, &"engagement-c6a-#{&1}")

      assert Enum.all?(
               restored,
               &(&1["metadata"]["engagement_id"] == "engagement-c6a")
             )
    end
  end

  defp build_entries(user, assistant, run_result) do
    Core.build_turn_entries(%{
      user_message: user,
      assistant_message: assistant,
      run_result: run_result,
      user_sent_at: @sent_at,
      assistant_completed_at: @completed_at,
      engagement_id: "engagement-c6a",
      turn_count: 4
    })
  end

  defp default_user, do: %{"role" => "user", "content" => "user text"}

  defp default_assistant do
    %AssistantMessage{
      content: "assistant text",
      started_at: @sent_at,
      completed_at: @completed_at
    }
  end

  defp restored_row(engagement_id, ordinal) do
    %{
      role: if(rem(ordinal, 2) == 0, do: :assistant, else: :user),
      content: "#{engagement_id}-#{ordinal}",
      metadata: %{"engagement_id" => engagement_id, "ordinal" => ordinal},
      taint: TaintEnvelope.missing_fallback(),
      taint_status: :legacy_unlabeled
    }
  end

  defp taint(source, level, sensitivity, sanitizations, confidence) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: sanitizations,
        confidence: confidence,
        source: source,
        chain: []
      })

    taint
  end

  defp source_labels(taint), do: MapSet.new([taint.source | taint.chain])

  defp verified_entry_taint(entry) do
    assert {:ok, envelope} = TaintEnvelope.verify(entry.metadata["taint"], entry.content)
    envelope.taint
  end

  defp monotonic_at_least?(candidate, source) do
    rank(Taint.levels(), candidate.level) >= rank(Taint.levels(), source.level) and
      rank(Taint.sensitivities(), candidate.sensitivity) >=
        rank(Taint.sensitivities(), source.sensitivity) and
      rank(Taint.confidences(), candidate.confidence) <=
        rank(Taint.confidences(), source.confidence) and
      Bitwise.band(candidate.sanitizations, source.sanitizations) ==
        candidate.sanitizations
  end

  defp rank(values, value), do: Enum.find_index(values, &(&1 == value))
end
