defmodule Arbor.Contracts.Coding.TaskEvidenceDescriptorTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.TaskEvidenceDescriptor

  @moduletag :fast

  test "constructs and projects the canonical closed JSON descriptor" do
    assert TaskEvidenceDescriptor.schema_version() == 1
    assert {:ok, descriptor} = TaskEvidenceDescriptor.new(valid_descriptor())
    assert descriptor.path == "/tmp/task/evidence.json"
    assert descriptor.byte_size == 1_024
    assert descriptor.schema_version == 1

    projected = TaskEvidenceDescriptor.to_map(descriptor)
    assert projected == valid_descriptor()
    assert {:ok, ^projected} = TaskEvidenceDescriptor.normalize(projected)
    assert TaskEvidenceDescriptor.valid?(projected)
    assert TaskEvidenceDescriptor.valid?(descriptor)
    assert {:ok, _json} = Jason.encode(projected)
  end

  test "accepts atom keys but rejects duplicate aliases and unknown fields" do
    atom_keys = %{
      path: "/tmp/task/evidence.json",
      sha256: String.duplicate("a", 64),
      byte_size: 1_024,
      schema_version: 1,
      task_id: "task-1"
    }

    assert {:ok, _descriptor} = TaskEvidenceDescriptor.new(atom_keys)

    duplicate = [{:path, "/tmp/task/evidence.json"}, {"path", "/tmp/other.json"}]
    assert {:error, {:duplicate_field, "path"}} = TaskEvidenceDescriptor.new(duplicate)

    assert {:error, {:unknown_field, "extra"}} =
             valid_descriptor()
             |> Map.delete("task_id")
             |> Map.put("extra", "closed")
             |> TaskEvidenceDescriptor.new()
  end

  test "rejects missing, malformed, and oversized objects without raising" do
    assert {:error, {:missing_field, "task_id"}} =
             valid_descriptor()
             |> Map.delete("task_id")
             |> TaskEvidenceDescriptor.new()

    malformed = [{:path, "/tmp/task/evidence.json"}, :not_a_pair]
    improper = [{:path, "/tmp/task/evidence.json"} | :not_a_list]

    assert {:error, _reason} = TaskEvidenceDescriptor.new(malformed)
    assert {:error, _reason} = TaskEvidenceDescriptor.new(improper)
    refute TaskEvidenceDescriptor.valid?(malformed)
    refute TaskEvidenceDescriptor.valid?(improper)

    oversized_map = Map.put(valid_descriptor(), "extra", "closed")
    oversized_list = Map.to_list(valid_descriptor()) ++ [{"extra", "closed"}]

    assert {:error, {:invalid_descriptor, :object_too_large}} =
             TaskEvidenceDescriptor.new(oversized_map)

    assert {:error, {:invalid_descriptor, :object_too_large}} =
             TaskEvidenceDescriptor.new(oversized_list)
  end

  test "rejects descriptor values at every stated validation boundary" do
    invalid_values = [
      {"path", "relative.json"},
      {"path", "/tmp/task/../evidence.json"},
      {"path", "/tmp/task/" <> String.duplicate("a", 4_087)},
      {"path", "/tmp/task/\n evidence.json"},
      {"path", <<"/tmp/task/invalid-", 0, "evidence.json">>},
      {"path", <<255>>},
      {"sha256", String.duplicate("A", 64)},
      {"sha256", String.duplicate("a", 63)},
      {"sha256", String.duplicate("a", 64) <> "0"},
      {"byte_size", -1},
      {"byte_size", 1_048_577},
      {"byte_size", 1_024.0},
      {"schema_version", 0},
      {"schema_version", 2},
      {"task_id", ""},
      {"task_id", String.duplicate("a", 513)},
      {"task_id", "task\tid"},
      {"task_id", <<"task-", 0, "id">>},
      {"task_id", <<255>>}
    ]

    for {field, value} <- invalid_values do
      refute TaskEvidenceDescriptor.valid?(Map.put(valid_descriptor(), field, value)),
             "expected #{field} boundary to be rejected"
    end
  end

  defp valid_descriptor do
    %{
      "path" => "/tmp/task/evidence.json",
      "sha256" => String.duplicate("a", 64),
      "byte_size" => 1_024,
      "schema_version" => 1,
      "task_id" => "task-1"
    }
  end
end
