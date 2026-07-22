defmodule Arbor.Orchestrator.CodingPlan.TranscriptStoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Arbor.AI.AcpTranscript
  alias Arbor.Contracts.Coding.TaskOutcomeRegistry
  alias Arbor.Orchestrator.CodingPlan.ArtifactStore

  @moduletag :fast
  @task_id "task_transcript_store"

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "coding_transcript_store_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    File.chmod!(base, 0o700)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{root: root}
  end

  test "multi-turn store retains the latest N in source order", %{root: root} do
    descriptors =
      Enum.map(0..39, fn index ->
        assert {:ok, descriptor} =
                 ArtifactStore.append_transcript_turn(
                   root,
                   @task_id,
                   turn(index, "prompt-#{index}", "response-#{index}")
                 )

        descriptor
      end)

    descriptor = List.last(descriptors)
    assert descriptor["turns_seen"] == 40
    assert descriptor["turns_retained"] == 32
    assert descriptor["turns_omitted"] == 8
    assert descriptor["turns_truncated"]
    assert ArtifactStore.valid_transcript_descriptor?(descriptor)

    assert {:ok, transcript} = ArtifactStore.read_transcript(root, @task_id)

    assert Enum.map(transcript["turns"], &get_in(&1, ["execution", "capture_index"])) ==
             Enum.to_list(8..39)

    assert get_in(hd(transcript["turns"]), ["prompt", "content", "text"]) == "prompt-8"

    assert get_in(List.last(transcript["turns"]), ["prompt", "content", "text"]) ==
             "prompt-39"
  end

  test "identical replay is deterministic and conflicting identity fails closed", %{root: root} do
    original = turn(0, "prompt", "response", captured_at: "2026-07-16T10:00:00Z")

    assert {:ok, first} =
             ArtifactStore.append_transcript_turn(root, @task_id, original)

    body = File.read!(first["path"])

    replay = turn(0, "prompt", "response", captured_at: "2026-07-16T11:00:00Z")

    assert {:ok, replayed} =
             ArtifactStore.append_transcript_turn(root, @task_id, replay)

    assert replayed == first
    assert File.read!(first["path"]) == body

    conflict = turn(0, "prompt", "different-response")

    assert {:error, {:turn_identity_conflict, turn_id}} =
             ArtifactStore.append_transcript_turn(root, @task_id, conflict)

    assert turn_id == original["turn_id"]
    assert File.read!(first["path"]) == body
  end

  test "exact task binding rejects append read and descriptor mismatches", %{root: root} do
    assert {:ok, _descriptor} =
             ArtifactStore.append_transcript_turn(root, @task_id, turn(0, "p", "r"))

    assert {:error, {:task_id_mismatch, "other-task", @task_id}} =
             ArtifactStore.append_transcript_turn(
               root,
               "other-task",
               turn(1, "other", "other")
             )

    assert {:error, {:task_id_mismatch, "other-task", @task_id}} =
             ArtifactStore.read_transcript(root, "other-task")

    assert {:error, {:task_id_mismatch, "other-task", @task_id}} =
             ArtifactStore.transcript_descriptor(root, "other-task")
  end

  test "aggregate bound is exercised and retains the latest complete turn", %{root: root} do
    for index <- 0..2 do
      assert {:ok, _descriptor} =
               ArtifactStore.append_transcript_turn(
                 root,
                 @task_id,
                 large_turn(index)
               )
    end

    assert {:ok, descriptor} = ArtifactStore.transcript_descriptor(root, @task_id)
    assert descriptor["aggregate_truncated"]
    assert descriptor["turns_seen"] == 3
    assert descriptor["turns_retained"] < 3
    assert descriptor["turns_omitted"] == 3 - descriptor["turns_retained"]
    assert descriptor["byte_size"] <= 512_000
    assert byte_size(File.read!(descriptor["path"])) <= 512_000

    assert {:ok, transcript} = ArtifactStore.read_transcript(root, @task_id)
    latest = List.last(transcript["turns"])
    assert get_in(latest, ["execution", "capture_index"]) == 2
    assert get_in(latest, ["prompt", "content", "text"]) == String.duplicate("p", 64_000)
  end

  test "publication is private atomic and descriptor contains no inline bodies", %{root: root} do
    assert {:ok, descriptor} =
             ArtifactStore.append_transcript_turn(
               root,
               @task_id,
               turn(0, "secret-prompt", "secret-response")
             )

    assert {:ok, %File.Stat{} = stat} = File.stat(descriptor["path"])
    assert (stat.mode &&& 0o777) == 0o600
    assert Path.expand(descriptor["path"]) == descriptor["path"]
    refute Map.has_key?(descriptor, "turns")
    refute Map.has_key?(descriptor, "stream_tail")
    refute Jason.encode!(descriptor) =~ "secret-prompt"
    assert Path.wildcard(Path.join(root, ".acp-transcript.json.tmp-*")) == []
  end

  test "security regression: rejects traversal non-absolute and symlinked roots", %{root: root} do
    assert {:error, {:invalid_root, :not_absolute}} =
             ArtifactStore.append_transcript_turn("relative/root", @task_id, turn(0, "p", "r"))

    traversal = Path.join(root, "..") <> "/" <> Path.basename(root)

    assert {:error, {:invalid_root, :not_canonical}} =
             ArtifactStore.append_transcript_turn(traversal, @task_id, turn(0, "p", "r"))

    link = root <> "-link"
    :ok = File.ln_s(root, link)
    on_exit(fn -> File.rm(link) end)

    assert {:error, {:invalid_root, _reason}} =
             ArtifactStore.append_transcript_turn(link, @task_id, turn(0, "p", "r"))
  end

  test "security regression: tamper and digest mismatch are rejected", %{root: root} do
    assert {:ok, descriptor} =
             ArtifactStore.append_transcript_turn(root, @task_id, turn(0, "p", "r"))

    transcript = Jason.decode!(File.read!(descriptor["path"]))

    tampered = Map.put(transcript, "aggregate_truncated", true)

    File.write!(descriptor["path"], Jason.encode!(tampered, pretty: true))

    assert {:error, :transcript_digest_mismatch} =
             ArtifactStore.read_transcript(root, @task_id)

    assert {:error, :transcript_digest_mismatch} =
             ArtifactStore.transcript_descriptor(root, @task_id)
  end

  test "security regression: oversized persisted input is rejected before an unbounded read", %{
    root: root
  } do
    path = Path.join(root, "acp-transcript.json")
    File.write!(path, :binary.copy("x", 512_001))
    File.chmod!(path, 0o600)

    assert {:error, :transcript_too_large} = ArtifactStore.read_transcript(root, @task_id)
    assert {:error, :transcript_too_large} = ArtifactStore.transcript_descriptor(root, @task_id)
  end

  test "strict schema rejects unknown inline and malformed fields", %{root: root} do
    unknown = Map.put(turn(0, "p", "r"), "inline_authority", %{"pid" => "<pid>"})

    assert {:error, :invalid_turn_shape} =
             ArtifactStore.append_transcript_turn(root, @task_id, unknown)

    malformed = put_in(turn(1, "p", "r"), ["stream_tail", "events_seen"], 9)

    assert {:error, :invalid_stream_counts} =
             ArtifactStore.append_transcript_turn(root, @task_id, malformed)

    bad_descriptor =
      valid_descriptor()
      |> Map.put("stream_tail", %{})

    refute ArtifactStore.valid_transcript_descriptor?(bad_descriptor)
  end

  test "terminal validation follows the closed registry and rejects coding statuses", %{
    root: root
  } do
    assert TaskOutcomeRegistry.transcript_terminal_status?("success")

    invalid = put_in(turn(0, "p", "r"), ["terminal", "status"], "change_committed")

    assert {:error, :invalid_terminal_status} =
             ArtifactStore.append_transcript_turn(root, @task_id, invalid)
  end

  test "hostile integer metadata is rejected before JSON publication", %{root: root} do
    huge_integer = Integer.pow(10, 100)

    oversized_original =
      put_in(turn(0, "p", "r"), ["prompt", "content", "original_bytes"], huge_integer)

    assert {:error, :invalid_original_byte_count} =
             ArtifactStore.append_transcript_turn(root, @task_id, oversized_original)

    oversized_counts =
      turn(1, "p", "r")
      |> put_in(["stream_tail", "events_seen"], huge_integer)
      |> put_in(["stream_tail", "events_omitted"], huge_integer)
      |> put_in(["stream_tail", "events_truncated"], true)

    assert {:error, :invalid_stream_counts} =
             ArtifactStore.append_transcript_turn(root, @task_id, oversized_counts)

    oversized_index = turn(2, "p", "r")
    execution = Map.put(oversized_index["execution"], "capture_index", 512)

    oversized_index =
      oversized_index
      |> Map.put("execution", execution)
      |> Map.put("turn_id", AcpTranscript.turn_id("exec_store_identity", 512))

    assert {:error, :invalid_capture_index} =
             ArtifactStore.append_transcript_turn(root, @task_id, oversized_index)

    assert Path.wildcard(Path.join(root, "*")) == []
  end

  test "descriptor reports absent only when no transcript exists", %{root: root} do
    assert {:error, :absent} = ArtifactStore.transcript_descriptor(root, @task_id)
  end

  defp turn(index, prompt, response, opts \\ []) do
    {:ok, turn} =
      AcpTranscript.build_turn(%{
        execution_id: "exec_store_identity",
        capture_index: index,
        prompt_kind: "initial",
        terminal_status: "success",
        prompt: prompt,
        response_text: response,
        stop_reason: "end_turn",
        provider: "grok",
        provider_session_id: "session-1",
        stream_tail: Keyword.get(opts, :stream_tail, AcpTranscript.empty_stream_tail()),
        captured_at: Keyword.get(opts, :captured_at, "2026-07-16T12:00:00Z")
      })

    turn
  end

  defp large_turn(index) do
    tail =
      Enum.reduce(1..64, AcpTranscript.empty_stream_tail(), fn event_index, acc ->
        AcpTranscript.append_stream_event(acc, %{
          "kind" => "text",
          "content" => String.duplicate(Integer.to_string(rem(event_index, 10)), 2_048)
        })
      end)

    turn(index, String.duplicate("p", 64_000), String.duplicate("r", 64_000), stream_tail: tail)
  end

  defp valid_descriptor do
    %{
      "path" => "/tmp/acp-transcript.json",
      "sha256" => String.duplicate("a", 64),
      "byte_size" => 100,
      "turns_retained" => 1,
      "turns_seen" => 1,
      "turns_omitted" => 0,
      "turns_truncated" => false,
      "aggregate_truncated" => false,
      "schema_version" => 1,
      "task_id" => @task_id
    }
  end
end
