defmodule Arbor.Contracts.Coding.TaskOutcomeTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.TaskOutcome

  @moduletag :fast

  @required_attrs %{
    version: 1,
    disposition: :succeeded,
    code: "implemented",
    phase: :worker_turn,
    origin: :worker,
    retry: :none
  }

  test "exposes schema and closed enum accessors" do
    assert TaskOutcome.schema_version() == 1
    assert TaskOutcome.dispositions() == ~w(succeeded requires_input rejected failed cancelled)

    assert TaskOutcome.phases() ==
             ~w(preflight workspace worker_start worker_turn validation review commit adoption cleanup control)

    assert TaskOutcome.origins() ==
             ~w(arbor security acp_transport provider worker validator reviewer operator runtime)

    assert TaskOutcome.retries() == ~w(none same_session new_session after_external_change)

    assert TaskOutcome.delivery_states() ==
             ~w(delivered not_delivered delivery_unknown cancelled provider_account_exhausted)

    assert TaskOutcome.completion_states() ==
             ~w(end_turn provider_error timeout inactivity_timeout stream_callback_failure stream_callback_timeout prompt_exit client_down cancelled)
  end

  test "normalizes atom, string, and keyword-style objects to deterministic JSON" do
    assert {:ok, %TaskOutcome{} = outcome} =
             TaskOutcome.new(
               @required_attrs
               |> Map.merge(%{
                 message: "Worker completed the requested change.",
                 diagnostic_refs: ["refs/arbor/diagnostics/1"],
                 evidence_ref: "refs/arbor/evidence/task-1",
                 delivery_state: :delivered,
                 completion_state: :end_turn,
                 worker_session_id: "worker-1",
                 provider_session_id: "provider-1",
                 provider: "codex",
                 requested_model: "gpt-5",
                 confirmed_model: "gpt-5"
               })
             )

    expected = %{
      "version" => 1,
      "disposition" => "succeeded",
      "code" => "implemented",
      "phase" => "worker_turn",
      "origin" => "worker",
      "retry" => "none",
      "message" => "Worker completed the requested change.",
      "diagnostic_refs" => ["refs/arbor/diagnostics/1"],
      "evidence_ref" => "refs/arbor/evidence/task-1",
      "delivery_state" => "delivered",
      "completion_state" => "end_turn",
      "worker_session_id" => "worker-1",
      "provider_session_id" => "provider-1",
      "provider" => "codex",
      "requested_model" => "gpt-5",
      "confirmed_model" => "gpt-5"
    }

    assert TaskOutcome.to_map(outcome) == expected
    assert TaskOutcome.to_map(outcome) == TaskOutcome.to_map(outcome)
    assert {:ok, _json} = Jason.encode(TaskOutcome.to_map(outcome))

    assert {:ok, keyword_outcome} =
             TaskOutcome.new(
               version: 1,
               disposition: :requires_input,
               code: "needs_review",
               phase: :review,
               origin: :reviewer,
               retry: :after_external_change
             )

    assert TaskOutcome.to_map(keyword_outcome) == %{
             "version" => 1,
             "disposition" => "requires_input",
             "code" => "needs_review",
             "phase" => "review",
             "origin" => "reviewer",
             "retry" => "after_external_change"
           }
  end

  test "requires all canonical fields and version one" do
    for field <- [:version, :disposition, :code, :phase, :origin, :retry] do
      field_name = Atom.to_string(field)

      assert {:error, {:missing_field, ^field_name}} =
               TaskOutcome.new(Map.delete(@required_attrs, field))
    end

    for version <- [0, 2, "1", nil, :one] do
      assert {:error, {:invalid_field, "version"}} =
               TaskOutcome.new(Map.put(@required_attrs, :version, version))
    end
  end

  test "rejects unknown fields, duplicate aliases, structs, and non-JSON values" do
    assert {:error, {:unknown_fields, ["capabilities"]}} =
             TaskOutcome.new(Map.put(@required_attrs, "capabilities", ["all"]))

    assert {:error, {:duplicate_fields, ["code"]}} =
             TaskOutcome.new([
               {:version, 1},
               {:disposition, :succeeded},
               {:code, "one"},
               {"code", "two"},
               {:phase, :worker_turn},
               {:origin, :worker},
               {:retry, :none}
             ])

    assert {:error, {:invalid_object, "task_outcome"}} = TaskOutcome.new(%URI{path: "/tmp"})

    assert {:error, {:invalid_object, "task_outcome"}} =
             TaskOutcome.new([
               {:version, 1},
               {:disposition, :succeeded},
               {:code, "x"} | :improper
             ])

    for {field, value} <- [
          {:code, self()},
          {:message, fn -> :not_json end},
          {:diagnostic_refs, [{:bad, :value}]},
          {:provider, %{nested: "map"}}
        ] do
      assert {:error, {:invalid_field, _field}} =
               TaskOutcome.new(Map.put(@required_attrs, field, value))
    end
  end

  test "rejects invalid enums and blank or oversized bounded strings" do
    for {field, value} <- [
          {:disposition, "unknown"},
          {:phase, "execute"},
          {:origin, "external"},
          {:retry, "forever"},
          {:delivery_state, "maybe"},
          {:completion_state, "unknown"},
          {:completion_state, "success"}
        ] do
      field_name = Atom.to_string(field)

      assert {:error, {:invalid_field, ^field_name}} =
               TaskOutcome.new(Map.put(@required_attrs, field, value))
    end

    for {field, value} <- [
          {:code, " "},
          {:message, "\0"},
          {:evidence_ref, String.duplicate("r", 513)},
          {:requested_model, "\n"},
          {:diagnostic_refs, List.duplicate("ref", 33)}
        ] do
      assert {:error, {:invalid_field, _field}} =
               TaskOutcome.new(Map.put(@required_attrs, field, value))
    end
  end

  test "accepts explicit null optional values and omits them from canonical JSON" do
    attrs =
      Map.merge(@required_attrs, %{
        message: nil,
        diagnostic_refs: nil,
        evidence_ref: nil,
        delivery_state: nil,
        completion_state: nil,
        worker_session_id: nil,
        provider_session_id: nil,
        provider: nil,
        requested_model: nil,
        confirmed_model: nil
      })

    assert {:ok, outcome} = TaskOutcome.new(attrs)
    assert outcome.diagnostic_refs == []

    assert TaskOutcome.to_map(outcome) == %{
             "version" => 1,
             "disposition" => "succeeded",
             "code" => "implemented",
             "phase" => "worker_turn",
             "origin" => "worker",
             "retry" => "none"
           }
  end

  test "registry-backed construction owns semantics and never classifies prose" do
    assert {:ok, outcome} =
             TaskOutcome.from_code("task_owner_died", %{
               "disposition" => "succeeded",
               "phase" => "commit",
               "origin" => "operator",
               "retry" => "none",
               "message" => "everything succeeded despite words"
             })

    assert TaskOutcome.to_map(outcome) == %{
             "version" => 1,
             "disposition" => "failed",
             "code" => "task_owner_died",
             "phase" => "control",
             "origin" => "runtime",
             "retry" => "new_session",
             "message" => "everything succeeded despite words"
           }

    assert {:error, {:unknown_task_outcome_code, "task_owner_died in prose"}} =
             TaskOutcome.from_code("task_owner_died in prose")
  end

  test "registered validation rejects caller-forged code semantics" do
    assert {:ok, canonical} = TaskOutcome.from_code("no_changes")
    assert {:ok, ^canonical} = TaskOutcome.validate_registered(TaskOutcome.to_map(canonical))

    forged =
      canonical
      |> TaskOutcome.to_map()
      |> Map.put("disposition", "failed")

    assert {:error, {:invalid_task_outcome, :registry_semantics_mismatch}} =
             TaskOutcome.validate_registered(forged)
  end
end
