defmodule Arbor.Orchestrator.DurableJsonTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.DurableJson

  test "projects through Jason semantics and hashes deterministically" do
    timestamp = ~U[2026-08-05 12:34:56Z]

    atom_shaped = %{
      state: :ready,
      nested: [%{answer: 42, at: timestamp}],
      enabled: true
    }

    string_shaped = %{
      "enabled" => true,
      "nested" => [%{"answer" => 42, "at" => DateTime.to_iso8601(timestamp)}],
      "state" => "ready"
    }

    assert {:ok, result} = DurableJson.project_and_digest(atom_shaped)
    assert result.projection == string_shaped
    assert result.encoding == "arbor_orchestrator_durable_json_v1"
    assert result.digest_algorithm == "sha256"
    assert byte_size(result.sha256) == 64

    assert {:ok, ^result} = DurableJson.project_and_digest(string_shaped)

    reordered =
      [{"state", "ready"}, {"enabled", true}, {"nested", string_shaped["nested"]}]
      |> Enum.into(%{})

    assert {:ok, ^result} = DurableJson.project_and_digest(reordered)
  end

  test "rejects duplicate object keys after JSON key normalization" do
    assert {:error, :duplicate_json_key} =
             DurableJson.project_and_digest(%{:same => 1, "same" => 2})

    assert {:error, :duplicate_json_key} =
             DurableJson.project_and_digest(%{"nested" => %{1 => "integer", "1" => "string"}})
  end

  test "supports a one megabyte string without an added digest ceiling" do
    value = String.duplicate("X", 1_000_000)

    assert {:ok, result} = DurableJson.project_and_digest(value)
    assert result.projection == value
    assert byte_size(result.sha256) == 64

    changed = "Y" <> binary_part(value, 1, byte_size(value) - 1)
    assert {:ok, changed_result} = DurableJson.project_and_digest(changed)
    assert changed_result.projection == changed
    refute changed_result.sha256 == result.sha256
  end

  test "supports large arrays, objects, node counts, and depth accepted by Jason" do
    large_array = Enum.to_list(1..100_000)
    large_object = Map.new(1..300, &{"key_#{&1}", &1})
    deep_value = Enum.reduce(1..64, "leaf", fn index, acc -> %{"d#{index}" => acc} end)

    value = %{
      "large_array" => large_array,
      "large_object" => large_object,
      "deep_value" => deep_value
    }

    assert {:ok, result} = DurableJson.project_and_digest(value)
    assert result.projection == value
    assert byte_size(result.sha256) == 64
  end

  test "returns bounded errors for terms Jason cannot project" do
    assert {:error, :unsupported_payload} = DurableJson.project_and_digest(self())
    assert {:error, :unsupported_payload} = DurableJson.project_and_digest(fn -> :ok end)
    assert {:error, :invalid_json_projection} = DurableJson.project_and_digest(<<255>>)
  end

  test "digest convenience is equivalent and preserves projection errors" do
    values = [
      %{"nested" => [%{state: :ready}, 42]},
      String.duplicate("X", 100_000),
      Enum.reduce(1..40, "leaf", fn index, acc -> %{"d#{index}" => acc} end)
    ]

    Enum.each(values, fn value ->
      assert {:ok, result} = DurableJson.project_and_digest(value)
      assert {:ok, digest} = DurableJson.digest(value)
      assert digest == result.sha256
      assert digest == String.downcase(digest)
    end)

    invalid_values = [
      self(),
      fn -> :ok end,
      <<255>>,
      %{:same => 1, "same" => 2}
    ]

    Enum.each(invalid_values, fn value ->
      assert DurableJson.digest(value) == error_only(DurableJson.project_and_digest(value))
    end)
  end

  defp error_only({:error, reason}), do: {:error, reason}
end
