defmodule Arbor.Agent.Orchestration.TaskInventoryProjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Orchestration.TaskInventoryProjection

  @moduletag :fast
  @timestamp ~U[2026-07-22 12:00:00Z]

  test "projects only bounded lifecycle and reconciliation evidence" do
    secret = "task-secret-must-not-cross-the-inventory-boundary"

    record =
      task_record("task-a", "agent-a", :done,
        pid: self(),
        task: secret,
        metadata: %{secret: secret},
        context: %{secret: secret},
        executor: {System, :cmd},
        ref: make_ref(),
        approval_answer_cap_id: secret,
        result: %{
          "payload" => %{secret: secret},
          "outcome" => canonical_outcome()
        },
        error: {:runtime_error, secret},
        controls: [
          %{"status" => "delivered", "message" => secret},
          %{"status" => "queued", "message" => secret}
        ]
      )

    inventory =
      TaskInventoryProjection.from_state(
        %{tasks: %{"task-a" => record}},
        %{},
        10,
        %{"task-a" => %{present: true, alive: true}}
      )

    task = hd(inventory["tasks"])
    encoded = Jason.encode!(inventory)

    assert inventory["schema_version"] == 1
    assert inventory["storage"] == %{"durability" => "volatile"}
    assert task["task_id"] == "task-a"
    assert task["agent_id"] == "agent-a"
    assert task["state"] == "done"
    assert task["owner_process"] == %{"present" => true, "alive" => true}
    assert task["control_counts"] == %{"closed" => 1, "open" => 1}
    assert task["evidence_present"] == false
    assert task["artifacts_present"] == false
    assert task["outcome"] == canonical_outcome()
    refute String.contains?(inspect(inventory["tasks"]), secret)
    refute String.contains?(encoded, secret)
    assert_json_clean(inventory)
  end

  test "preserves exact canonical terminal outcomes and only presence booleans for artifacts" do
    record =
      task_record("task-outcome", "agent-a", :done,
        result: %{
          "payload" => %{
            "artifacts" => %{"coding_plan_path" => "/private/plan"},
            "task_evidence" => %{"evidence_ref" => "private-evidence"}
          },
          "outcome" => canonical_outcome()
        }
      )

    inventory =
      TaskInventoryProjection.from_state(
        %{tasks: %{"task-outcome" => record}},
        %{},
        10,
        %{}
      )

    task = hd(inventory["tasks"])

    assert task["outcome"] == canonical_outcome()
    assert task["evidence_present"] == true
    assert task["artifacts_present"] == true
    refute Map.has_key?(task, "path")
    refute Map.has_key?(task, "evidence_ref")
    assert_json_clean(inventory)
  end

  test "counts malformed records without exposing terms" do
    secret = "malformed-secret"

    inventory =
      TaskInventoryProjection.from_state(
        %{
          tasks: %{
            "bad" => %{task_id: "task-bad", secret: secret, pid: self()},
            "good" => task_record("task-good", "agent-a", :running)
          }
        },
        %{},
        10,
        %{}
      )

    assert inventory["counts"]["observed"] == 2
    assert inventory["counts"]["malformed"] == 1
    assert Enum.map(inventory["tasks"], & &1["task_id"]) == ["task-good"]
    refute String.contains?(Jason.encode!(inventory), secret)
    assert_json_clean(inventory)
  end

  test "filters, hard bounds, and lexical ordering are deterministic" do
    state = %{
      tasks: %{
        "z" => task_record("task-z", "agent-b", :running),
        "a2" => task_record("task-b", "agent-a", :done),
        "a1" => task_record("task-a", "agent-a", :running),
        "a3" => task_record("task-c", "agent-a", :running)
      }
    }

    opts = %{agent_id: "agent-a", state: :running}
    first = TaskInventoryProjection.from_state(state, opts, 1, %{})
    second = TaskInventoryProjection.from_state(state, opts, 1, %{})

    assert first == second
    assert first["counts"]["observed"] == 4
    assert first["counts"]["matching"] == 2
    assert first["counts"]["returned"] == 1
    assert first["counts"]["truncated"] == 1
    assert first["truncated"] == true
    assert hd(first["tasks"])["task_id"] == "task-a"
  end

  test "projection is side-effect free" do
    state = %{tasks: %{"task-a" => task_record("task-a", "agent-a", :running)}}

    before = state
    inventory = TaskInventoryProjection.from_state(state, %{}, 10, %{})

    assert state == before
    assert inventory["counts"]["returned"] == 1
  end

  defp task_record(task_id, agent_id, state, overrides \\ []) do
    %{
      task_id: task_id,
      agent_id: agent_id,
      state: state,
      current_step: "running",
      waiting_on: nil,
      started_at: @timestamp,
      updated_at: @timestamp,
      completed_at: if(state == :running, do: nil, else: @timestamp),
      controls: [],
      result: nil,
      error: nil,
      pid: nil,
      ref: nil,
      task: "redacted",
      metadata: %{},
      context: %{},
      executor: nil
    }
    |> Map.merge(Map.new(overrides))
  end

  defp canonical_outcome do
    %{
      "version" => 1,
      "disposition" => "succeeded",
      "code" => "change_committed",
      "phase" => "commit",
      "origin" => "worker",
      "retry" => "none"
    }
  end

  defp assert_json_clean(term) do
    assert {:ok, _decoded} = Jason.decode(Jason.encode!(term))
  end
end
