defmodule Arbor.Contracts.Coding.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Diagnostic

  @moduletag :fast

  test "constructs a canonical JSON-clean diagnostic" do
    assert Diagnostic.schema_version() == 1

    assert Diagnostic.phases() ==
             ~w(preflight workspace worker_start worker_turn validation review commit adoption cleanup control)

    assert Diagnostic.decisions() == ~w(passed blocked degraded unavailable)

    assert {:ok, diagnostic} =
             Diagnostic.new(
               version: 1,
               gate_id: "workspace_root",
               phase: :preflight,
               decision: :passed,
               code: "root_verified",
               observed_at: "2026-07-22T12:00:00-05:00",
               message: "workspace is available"
             )

    assert diagnostic.version == 1
    assert diagnostic.phase == "preflight"
    assert diagnostic.observed_at == "2026-07-22T17:00:00Z"

    assert Diagnostic.to_map(diagnostic) == %{
             "version" => 1,
             "gate_id" => "workspace_root",
             "phase" => "preflight",
             "decision" => "passed",
             "code" => "root_verified",
             "message" => "workspace is available",
             "observed_at" => "2026-07-22T17:00:00Z"
           }

    assert {:ok, _json} = diagnostic |> Diagnostic.to_map() |> Jason.encode()
  end

  test "accepts string-keyed objects and rejects structs, aliases, unknown keys, and malformed values" do
    attrs = %{
      "version" => 1,
      "gate_id" => "catalog",
      "phase" => "validation",
      "decision" => "degraded",
      "code" => "tool_unavailable",
      "observed_at" => "2026-07-22T12:00:00Z",
      "evidence_ref" => "refs/arbor/evidence/catalog.json"
    }

    assert {:ok, diagnostic} = Diagnostic.new(attrs)
    assert Diagnostic.to_map(diagnostic) == attrs
    assert {:ok, ^attrs} = Diagnostic.normalize(attrs)

    assert {:error, {:duplicate_field, "gate_id"}} =
             Diagnostic.new([{:gate_id, "one"}, {"gate_id", "two"} | valid_keyword()])

    assert {:error, {:unknown_field, "secret"}} =
             Diagnostic.new(Map.put(attrs, "secret", "nope"))

    assert {:error, {:invalid_diagnostic, :struct_not_allowed}} = Diagnostic.new(diagnostic)

    for value <- [self(), {:not_json, 1}, %{nested: :value}, ["not", "a", "string"], 1.0] do
      refute Diagnostic.valid?(Map.put(attrs, "message", value))
    end
  end

  test "rejects missing, invalid, control-bearing, and oversized fields without raising" do
    attrs = valid_keyword()

    assert {:error, {:missing_field, "version"}} =
             attrs |> Keyword.delete(:version) |> Diagnostic.new()

    invalid = [
      {:version, 2},
      {:gate_id, " "},
      {:phase, "unknown"},
      {:decision, "unknown"},
      {:code, ""},
      {:message, String.duplicate("x", 257)},
      {:observed_at, "2026-07-22T12:00:00"},
      {:observed_at, "2026-07-22T12:00:00Z\n"},
      {:evidence_ref, nil}
    ]

    for {field, value} <- invalid do
      if field == :evidence_ref do
        assert {:ok, _} = Diagnostic.new(Keyword.put(attrs, field, value))
      else
        refute Diagnostic.valid?(Keyword.put(attrs, field, value)), "expected #{field} to fail"
      end
    end

    oversized = Enum.map(1..10, &{"unknown_#{&1}", "value"})
    assert {:error, {:invalid_diagnostic, :object_too_large}} = Diagnostic.new(oversized)

    malformed = [{:version, 1}, :not_a_pair]
    improper = [{:version, 1} | :not_a_list]
    assert {:error, _} = Diagnostic.new(malformed)
    assert {:error, _} = Diagnostic.new(improper)
  end

  defp valid_keyword do
    [
      version: 1,
      gate_id: "gate",
      phase: :control,
      decision: :blocked,
      code: "blocked",
      observed_at: "2026-07-22T12:00:00Z"
    ]
  end
end
