defmodule Arbor.Contracts.Coding.DesignArtifactDescriptorTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.DesignArtifactDescriptor

  @moduletag :fast

  test "max_bytes/0 is the sole design-body size authority at 32768" do
    assert DesignArtifactDescriptor.max_bytes() == 32_768
  end

  test "constructs and projects the canonical closed JSON descriptor" do
    assert DesignArtifactDescriptor.schema_version() == 1
    assert {:ok, descriptor} = DesignArtifactDescriptor.new(valid_descriptor())
    assert descriptor.path == "/tmp/task/coding-design-attempt-1.txt"
    assert descriptor.byte_size == 1_024
    assert descriptor.design_attempt == 1
    assert descriptor.schema_version == 1

    projected = DesignArtifactDescriptor.to_map(descriptor)
    assert projected == valid_descriptor()
    assert {:ok, ^projected} = DesignArtifactDescriptor.normalize(projected)
    assert DesignArtifactDescriptor.valid?(projected)
    assert DesignArtifactDescriptor.valid?(descriptor)
    assert {:ok, _json} = Jason.encode(projected)
  end

  test "accepts atom keys but rejects duplicate aliases and unknown fields" do
    atom_keys = %{
      path: "/tmp/task/coding-design-attempt-1.txt",
      sha256: String.duplicate("a", 64),
      byte_size: 1_024,
      schema_version: 1,
      task_id: "task-1",
      design_attempt: 1
    }

    assert {:ok, _descriptor} = DesignArtifactDescriptor.new(atom_keys)

    duplicate = [
      {:path, "/tmp/task/coding-design-attempt-1.txt"},
      {"path", "/tmp/other.txt"}
    ]

    assert {:error, {:duplicate_field, "path"}} = DesignArtifactDescriptor.new(duplicate)

    assert {:error, {:unknown_field, "extra"}} =
             valid_descriptor()
             |> Map.delete("task_id")
             |> Map.put("extra", "closed")
             |> DesignArtifactDescriptor.new()
  end

  test "rejects missing, malformed, and oversized objects without raising" do
    assert {:error, {:missing_field, "task_id"}} =
             valid_descriptor()
             |> Map.delete("task_id")
             |> DesignArtifactDescriptor.new()

    malformed = [{:path, "/tmp/task/coding-design-attempt-1.txt"}, :not_a_pair]
    improper = [{:path, "/tmp/task/coding-design-attempt-1.txt"} | :not_a_list]

    assert {:error, _reason} = DesignArtifactDescriptor.new(malformed)
    assert {:error, _reason} = DesignArtifactDescriptor.new(improper)
    refute DesignArtifactDescriptor.valid?(malformed)
    refute DesignArtifactDescriptor.valid?(improper)

    oversized_map = Map.put(valid_descriptor(), "extra", "closed")
    oversized_list = Map.to_list(valid_descriptor()) ++ [{"extra", "closed"}]

    assert {:error, {:invalid_descriptor, :object_too_large}} =
             DesignArtifactDescriptor.new(oversized_map)

    assert {:error, {:invalid_descriptor, :object_too_large}} =
             DesignArtifactDescriptor.new(oversized_list)
  end

  test "rejects descriptor values at every stated validation boundary" do
    max = DesignArtifactDescriptor.max_bytes()

    invalid_values = [
      {"path", "relative.txt"},
      {"path", "/tmp/task/../design.txt"},
      {"path", "/tmp/task/" <> String.duplicate("a", 4_087)},
      {"path", "/tmp/task/\n design.txt"},
      {"path", <<"/tmp/task/invalid-", 0, "design.txt">>},
      {"path", <<255>>},
      {"sha256", String.duplicate("A", 64)},
      {"sha256", String.duplicate("a", 63)},
      {"sha256", String.duplicate("a", 64) <> "0"},
      {"byte_size", 0},
      {"byte_size", -1},
      {"byte_size", max + 1},
      {"byte_size", 1_024.0},
      {"schema_version", 0},
      {"schema_version", 2},
      {"task_id", ""},
      {"task_id", String.duplicate("a", 513)},
      {"task_id", "task\tid"},
      {"task_id", <<"task-", 0, "id">>},
      {"task_id", <<255>>},
      {"design_attempt", 0},
      {"design_attempt", -1},
      {"design_attempt", 1_000_001},
      {"design_attempt", 1.0}
    ]

    for {field, value} <- invalid_values do
      refute DesignArtifactDescriptor.valid?(Map.put(valid_descriptor(), field, value)),
             "expected #{field} boundary to be rejected"
    end

    assert DesignArtifactDescriptor.valid?(
             Map.put(valid_descriptor(), "byte_size", DesignArtifactDescriptor.max_bytes())
           )
  end

  defp valid_descriptor do
    %{
      "path" => "/tmp/task/coding-design-attempt-1.txt",
      "sha256" => String.duplicate("a", 64),
      "byte_size" => 1_024,
      "schema_version" => 1,
      "task_id" => "task-1",
      "design_attempt" => 1
    }
  end
end
