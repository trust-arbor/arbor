defmodule Arbor.Voice.TranscriptRecorderTest do
  @moduledoc """
  VP-04D2A: `Arbor.Voice.TranscriptRecorder.record/5` — the isolated
  engagement-transcript write boundary. Fully hermetic via
  `Arbor.Voice.Test.FakeComms`; never touches real Comms/Persistence.

  Partial durable-transcript proof tagged `VOICE-3`. The VOICE-3 planned
  marker stays planned until Session call-site ordering lands.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Voice.Test.FakeComms
  alias Arbor.Voice.TranscriptRecorder

  defmodule RaisingComms do
    @moduledoc false
    def record_engagement_turn(_a, _e, _u, _as, _o), do: raise("comms boom")
  end

  defmodule ThrowingComms do
    @moduledoc false
    def record_engagement_turn(_a, _e, _u, _as, _o), do: throw(:comms_throw)
  end

  defmodule ExitingComms do
    @moduledoc false
    def record_engagement_turn(_a, _e, _u, _as, _o), do: exit(:comms_exit)
  end

  defp voice_message(opts \\ []) do
    content = Keyword.get(opts, :content, "hello from voice")
    sent_at = Keyword.get(opts, :sent_at, ~U[2026-01-01 00:00:00.000000Z])
    engagement_id = Keyword.get(opts, :engagement_id, "eng_voice_1")

    UserMessage.from_voice(content,
      sent_at: sent_at,
      sender_id: Keyword.get(opts, :sender_id, "human_alice"),
      transport_metadata:
        Keyword.get(opts, :transport_metadata, %{
          backend: "xai_realtime",
          secret: "must-not-leak",
          device: "mac"
        })
    )
    |> UserMessage.with_engagement(engagement_id)
  end

  setup do
    {:ok, agent} = FakeComms.start()
    %{agent: agent}
  end

  # ── happy path: one ordered Comms call, exact provenance ──

  describe "record/5 success path" do
    @tag spec: "VOICE-3"
    test "calls Comms exactly once with ordered user/assistant entries, exact timestamps, and engagement provenance",
         %{agent: agent} do
      sent_at = ~U[2026-03-15 12:00:00.000000Z]
      completed_at = ~U[2026-03-15 12:00:02.500000Z]
      msg = voice_message(content: "utterance text", sent_at: sent_at, engagement_id: "eng_abc")

      assert {:ok, 2} =
               TranscriptRecorder.record(
                 "agent_1",
                 msg,
                 "raw assistant reply",
                 completed_at,
                 comms: FakeComms,
                 backend: :xai_realtime,
                 mode: "conversation"
               )

      assert FakeComms.call_count(agent) == 1

      assert [
               {"agent_1", "eng_abc", user_entry, assistant_entry, forwarded_opts}
             ] = FakeComms.calls(agent)

      assert user_entry.content == "utterance text"
      assert user_entry.sent_at == sent_at

      assert user_entry.metadata == %{
               "transport" => "voice",
               "backend" => "xai_realtime",
               "mode" => "conversation"
             }

      assert assistant_entry.content == "raw assistant reply"
      assert assistant_entry.completed_at == completed_at

      assert assistant_entry.metadata == %{
               "transport" => "voice",
               "backend" => "xai_realtime",
               "mode" => "conversation"
             }

      # Only :persistence is forwardable; absent here so opts is empty.
      assert forwarded_opts == []
    end

    @tag spec: "VOICE-3"
    test "forwards only :persistence and never copies transport_metadata, sender fields, or arbitrary opts",
         %{agent: agent} do
      msg =
        voice_message(
          sender_id: "human_alice",
          transport_metadata: %{
            backend: "should-not-copy",
            credential: "sk-secret",
            raw_provider_state: %{token: "x"}
          }
        )

      persistence = :test_persistence_double

      assert {:ok, 2} =
               TranscriptRecorder.record(
                 "agent_1",
                 msg,
                 "ok",
                 ~U[2026-01-01 00:00:01.000000Z],
                 comms: FakeComms,
                 persistence: persistence,
                 backend: "xai_realtime",
                 mode: :local
               )

      assert [
               {_agent, "eng_voice_1", user_entry, assistant_entry, forwarded_opts}
             ] = FakeComms.calls(agent)

      assert forwarded_opts == [persistence: persistence]

      # Source-owned metadata only — no credential/sender/transport_metadata leak.
      assert user_entry.metadata == %{
               "transport" => "voice",
               "backend" => "xai_realtime",
               "mode" => "local"
             }

      assert assistant_entry.metadata == user_entry.metadata
      refute Map.has_key?(user_entry, :sender_id)
      refute Map.has_key?(user_entry.metadata, "credential")
      refute Map.has_key?(user_entry.metadata, "secret")
      refute Map.has_key?(user_entry.metadata, "raw_provider_state")
      refute Map.has_key?(user_entry.metadata, "device")
    end

    @tag spec: "VOICE-3"
    test "persists raw assistant text unchanged — Speakable is not invoked", %{agent: agent} do
      raw = """
      ```elixir
      def secret_code, do: :ok
      ```

      See https://example.com/path and more prose that Speakable would strip.
      """

      assert {:ok, 2} =
               TranscriptRecorder.record(
                 "agent_1",
                 voice_message(),
                 raw,
                 ~U[2026-01-01 00:00:01.000000Z],
                 comms: FakeComms
               )

      assert [{_a, _e, _u, assistant_entry, _opts}] = FakeComms.calls(agent)
      assert assistant_entry.content == raw
    end

    test "defaults metadata to transport-only when backend/mode are omitted", %{agent: agent} do
      assert {:ok, 2} =
               TranscriptRecorder.record(
                 "agent_1",
                 voice_message(),
                 "reply",
                 ~U[2026-01-01 00:00:01.000000Z],
                 comms: FakeComms
               )

      assert [{_, _, user_entry, assistant_entry, _}] = FakeComms.calls(agent)
      assert user_entry.metadata == %{"transport" => "voice"}
      assert assistant_entry.metadata == %{"transport" => "voice"}
    end

    test "normalizes backend/mode atoms with Atom.to_string/1 and accepts UTF-8 binaries",
         %{agent: agent} do
      assert {:ok, 2} =
               TranscriptRecorder.record(
                 "agent_1",
                 voice_message(),
                 "reply",
                 ~U[2026-01-01 00:00:01.000000Z],
                 comms: FakeComms,
                 backend: :cloud,
                 mode: "hands_free"
               )

      assert [{_, _, user_entry, _, _}] = FakeComms.calls(agent)
      assert user_entry.metadata["backend"] == "cloud"
      assert user_entry.metadata["mode"] == "hands_free"
    end
  end

  # ── return semantics: unchanged success/error; no forge after raise/throw/exit ──

  describe "record/5 return propagation" do
    test "returns Comms success and error results unchanged", %{agent: agent} do
      msg = voice_message()
      completed = ~U[2026-01-01 00:00:01.000000Z]

      assert {:ok, 2} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed, comms: FakeComms)

      FakeComms.set_result(agent, {:error, :append_failed})

      assert {:error, :append_failed} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed, comms: FakeComms)

      FakeComms.set_result(agent, {:error, {:invalid_user_entry, :timestamps_out_of_order}})

      assert {:error, {:invalid_user_entry, :timestamps_out_of_order}} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed, comms: FakeComms)

      # Two recorded attempts after the first success (set_result still records).
      assert FakeComms.call_count(agent) == 3
    end

    test "does not catch or forge success after Comms raise/throw/exit" do
      msg = voice_message()
      completed = ~U[2026-01-01 00:00:01.000000Z]

      assert_raise RuntimeError, "comms boom", fn ->
        TranscriptRecorder.record("agent_1", msg, "ok", completed, comms: RaisingComms)
      end

      assert catch_throw(
               TranscriptRecorder.record("agent_1", msg, "ok", completed, comms: ThrowingComms)
             ) == :comms_throw

      assert catch_exit(
               TranscriptRecorder.record("agent_1", msg, "ok", completed, comms: ExitingComms)
             ) == :comms_exit
    end
  end

  # ── preflight: reject before Comms observes a call ──

  describe "record/5 preflight validation" do
    test "rejects missing, blank, oversized, or invalid UTF-8 engagement_id without calling Comms",
         %{agent: agent} do
      completed = ~U[2026-01-01 00:00:01.000000Z]

      for {engagement_id, reason} <- [
            {nil, :not_a_string},
            {"", :blank},
            {"   ", :blank},
            {String.duplicate("a", 257), :too_large},
            {<<0xFF, 0xFE, "bad">>, :not_utf8},
            {123, :not_a_string}
          ] do
        msg = voice_message(engagement_id: engagement_id)

        assert {:error, {:invalid_id, :engagement_id, ^reason}} =
                 TranscriptRecorder.record("agent_1", msg, "ok", completed, comms: FakeComms)
      end

      assert FakeComms.call_count(agent) == 0
    end

    test "rejects non-voice or non-UserMessage envelopes without calling Comms", %{agent: agent} do
      completed = ~U[2026-01-01 00:00:01.000000Z]

      dashboard =
        UserMessage.from_dashboard("hi", "human")
        |> UserMessage.with_engagement("eng_1")

      assert {:error, {:invalid_user_message, :not_voice}} =
               TranscriptRecorder.record("agent_1", dashboard, "ok", completed, comms: FakeComms)

      assert {:error, {:invalid_user_message, :not_a_user_message}} =
               TranscriptRecorder.record("agent_1", "bare string", "ok", completed,
                 comms: FakeComms
               )

      assert {:error, {:invalid_user_message, :not_a_user_message}} =
               TranscriptRecorder.record("agent_1", nil, "ok", completed, comms: FakeComms)

      assert FakeComms.call_count(agent) == 0
    end

    test "rejects a non-DateTime completed_at without calling Comms", %{agent: agent} do
      assert {:error, {:invalid_timestamp, :completed_at}} =
               TranscriptRecorder.record(
                 "agent_1",
                 voice_message(),
                 "ok",
                 "2026-01-01T00:00:01Z",
                 comms: FakeComms
               )

      assert FakeComms.call_count(agent) == 0
    end

    test "rejects unknown keys, duplicate keys, non-keyword opts, and bad backend/mode before Comms",
         %{agent: agent} do
      msg = voice_message()
      completed = ~U[2026-01-01 00:00:01.000000Z]

      assert {:error, {:invalid_opts, {:unknown_keys, [:bogus]}}} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed,
                 comms: FakeComms,
                 bogus: true
               )

      assert {:error, {:invalid_opts, :duplicate_keys}} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed, [
                 {:comms, FakeComms},
                 {:comms, FakeComms}
               ])

      assert {:error, {:invalid_opts, :not_a_keyword_list}} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed, %{comms: FakeComms})

      assert {:error, {:invalid_opts, :invalid_metadata_value}} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed,
                 comms: FakeComms,
                 backend: %{nested: true}
               )

      assert {:error, {:invalid_opts, :invalid_metadata_value}} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed,
                 comms: FakeComms,
                 mode: ["list"]
               )

      assert {:error, {:invalid_opts, :invalid_metadata_value}} =
               TranscriptRecorder.record("agent_1", msg, "ok", completed,
                 comms: FakeComms,
                 backend: <<0xFF, 0xFE>>
               )

      assert FakeComms.call_count(agent) == 0
    end

    test "does not accept a second engagement-id argument or derive one from agent/user identity",
         %{agent: agent} do
      # engagement_id comes only from the tagged message — a different agent_id
      # must not rewrite provenance.
      msg = voice_message(engagement_id: "eng_from_message")

      assert {:ok, 2} =
               TranscriptRecorder.record(
                 "agent_totally_different",
                 msg,
                 "ok",
                 ~U[2026-01-01 00:00:01.000000Z],
                 comms: FakeComms
               )

      assert [{"agent_totally_different", "eng_from_message", _, _, _}] = FakeComms.calls(agent)

      # Unknown engagement-related opt keys are rejected (no alternate channel).
      assert {:error, {:invalid_opts, {:unknown_keys, unknown}}} =
               TranscriptRecorder.record(
                 "agent_1",
                 voice_message(engagement_id: "eng_x"),
                 "ok",
                 ~U[2026-01-01 00:00:01.000000Z],
                 comms: FakeComms,
                 engagement_id: "spoofed"
               )

      assert :engagement_id in unknown
      assert FakeComms.call_count(agent) == 1
    end
  end
end
