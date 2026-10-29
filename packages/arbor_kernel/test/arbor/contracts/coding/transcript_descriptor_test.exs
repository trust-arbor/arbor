defmodule Arbor.Contracts.Coding.TranscriptDescriptorTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.TranscriptDescriptor

  @moduletag :fast

  test "constructs and projects the canonical closed JSON descriptor" do
    assert {:ok, descriptor} = TranscriptDescriptor.new(valid_descriptor())
    assert descriptor.turns_seen == 3
    assert descriptor.turns_retained == 2
    assert descriptor.turns_omitted == 1

    projected = TranscriptDescriptor.to_map(descriptor)
    assert projected == valid_descriptor()
    assert {:ok, ^projected} = TranscriptDescriptor.normalize(projected)
    assert TranscriptDescriptor.valid?(projected)
    assert {:ok, _json} = Jason.encode(projected)
  end

  test "accepts atom keys but rejects duplicate aliases and unknown fields" do
    atom_keys = %{
      path: "/tmp/task/acp-transcript.json",
      sha256: String.duplicate("a", 64),
      byte_size: 128,
      turns_retained: 2,
      turns_seen: 3,
      turns_omitted: 1,
      turns_truncated: true,
      aggregate_truncated: false,
      schema_version: 1,
      task_id: "task-1"
    }

    assert {:ok, _descriptor} = TranscriptDescriptor.new(atom_keys)

    duplicate = [{:path, "/tmp/task/acp-transcript.json"}, {"path", "/tmp/other.json"}]
    assert {:error, {:duplicate_field, "path"}} = TranscriptDescriptor.new(duplicate)

    assert {:error, {:unknown_field, "turns"}} =
             valid_descriptor()
             |> Map.delete("task_id")
             |> Map.put("turns", [])
             |> TranscriptDescriptor.new()
  end

  test "rejects noncanonical paths bad digests oversized artifacts and bad task IDs" do
    for invalid <- [
          Map.put(valid_descriptor(), "path", "relative.json"),
          Map.put(valid_descriptor(), "path", "/tmp/x/../descriptor.json"),
          Map.put(valid_descriptor(), "sha256", String.duplicate("A", 64)),
          Map.put(valid_descriptor(), "byte_size", 512_001),
          Map.put(valid_descriptor(), "task_id", "bad\nid")
        ] do
      refute TranscriptDescriptor.valid?(invalid)
    end
  end

  test "rejects inconsistent retention facts and missing fields" do
    refute TranscriptDescriptor.valid?(Map.put(valid_descriptor(), "turns_omitted", 0))
    refute TranscriptDescriptor.valid?(Map.put(valid_descriptor(), "turns_truncated", false))

    assert {:error, {:missing_field, "task_id"}} =
             valid_descriptor()
             |> Map.delete("task_id")
             |> TranscriptDescriptor.new()
  end

  test "bounds counts to store capacity and handles malformed lists without raising" do
    refute TranscriptDescriptor.valid?(Map.put(valid_descriptor(), "turns_retained", 33))
    refute TranscriptDescriptor.valid?(Map.put(valid_descriptor(), "turns_seen", 513))
    refute TranscriptDescriptor.valid?(Map.put(valid_descriptor(), "turns_omitted", 513))

    improper = [{:path, "/tmp/x.json"} | :not_a_list]
    assert {:error, _reason} = TranscriptDescriptor.new(improper)
    refute TranscriptDescriptor.valid?(improper)

    malformed = [{:path, "/tmp/x.json"}, :not_a_pair]
    assert {:error, {:invalid_descriptor, :object_required}} = TranscriptDescriptor.new(malformed)
    refute TranscriptDescriptor.valid?(malformed)
  end

  test "rejects oversized map and list objects before field normalization" do
    oversized_map =
      valid_descriptor()
      |> Map.put("extra-1", 1)

    assert {:error, {:invalid_descriptor, :object_too_large}} =
             TranscriptDescriptor.new(oversized_map)

    oversized_list = Map.to_list(valid_descriptor()) ++ [{"extra-1", 1}]

    assert {:error, {:invalid_descriptor, :object_too_large}} =
             TranscriptDescriptor.new(oversized_list)
  end

  defp valid_descriptor do
    %{
      "path" => "/tmp/task/acp-transcript.json",
      "sha256" => String.duplicate("a", 64),
      "byte_size" => 128,
      "turns_retained" => 2,
      "turns_seen" => 3,
      "turns_omitted" => 1,
      "turns_truncated" => true,
      "aggregate_truncated" => false,
      "schema_version" => 1,
      "task_id" => "task-1"
    }
  end
end
