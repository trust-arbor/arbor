defmodule Arbor.Orchestrator.CodingPlan.NormalizerTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.Normalizer

  @moduletag :fast

  @legacy_task %{
    "kind" => "coding_change",
    "task" => "Implement the normalizer",
    "repo_path" => "/workspace/arbor",
    "acp_agent" => "grok"
  }

  @authority_keys ~w(
    action_executor
    actions
    actions_executor
    agent_id
    authorization
    capabilities
    edges
    engine
    engine_module
    graph
    graph_path
    identity
    module
    nodes
    path
    principal_id
    private_key
    signer
    signing_key
    task_id
  )

  describe "legacy task normalization" do
    test "preserves compatibility defaults and task text" do
      task_text = "  Keep task whitespace exactly  "

      assert {:ok, %Plan{} = plan} =
               Normalizer.normalize_task(%{@legacy_task | "task" => task_text})

      assert plan.task == task_text
      assert plan.repo_root == "/workspace/arbor"
      assert plan.base_ref == "HEAD"

      assert plan.worker == %{
               "provider" => "grok",
               "model" => nil,
               "permission_mode" => "default",
               "use_pool" => true,
               "resume_session_id" => nil
             }

      assert plan.workspace_policy == %{
               "mode" => "isolated",
               "branch_name" => nil,
               "worktree_base_dir" => nil
             }

      assert plan.review_profile == "binding"

      assert plan.output == %{
               "commit" => true,
               "draft_pr" => false,
               "retain_workspace" => true
             }
    end

    test "trims compatibility strings and maps every optional field" do
      task =
        Map.merge(@legacy_task, %{
          "repo_path" => "  /workspace/arbor  ",
          "acp_agent" => "  grok  ",
          "base_ref" => "  main  ",
          "branch_name" => "  feature/plan  ",
          "worktree_base_dir" => "  /tmp/worktrees  ",
          "open_pr" => "TRUE",
          "submit_review" => "false"
        })

      assert {:ok, plan} = Normalizer.normalize_task(task)
      assert plan.repo_root == "/workspace/arbor"
      assert plan.base_ref == "main"
      assert plan.worker["provider"] == "grok"
      assert plan.workspace_policy["branch_name"] == "feature/plan"
      assert plan.workspace_policy["worktree_base_dir"] == "/tmp/worktrees"
      assert plan.output["draft_pr"]
      assert plan.review_profile == "none"
    end

    test "accepts all current boolean compatibility forms" do
      truthy = [true, "true", "TRUE", "TrUe", " true ", "1"]
      falsey = [false, "false", "FALSE", "FaLsE", " false ", "0"]

      for value <- truthy do
        assert {:ok, plan} = Normalizer.normalize_task(Map.put(@legacy_task, "open_pr", value))
        assert plan.output["draft_pr"]
      end

      for value <- falsey do
        assert {:ok, plan} =
                 Normalizer.normalize_task(Map.put(@legacy_task, "submit_review", value))

        assert plan.review_profile == "none"
      end
    end

    test "preserves submit_review=false as the legacy-only none review profile" do
      assert {:ok, plan} =
               @legacy_task
               |> Map.put("submit_review", false)
               |> Normalizer.normalize_task()

      assert plan.review_profile == "none"
    end

    test "treats nil optional compatibility values as omitted" do
      task =
        Map.merge(@legacy_task, %{
          "base_ref" => nil,
          "branch_name" => nil,
          "worktree_base_dir" => nil,
          "open_pr" => nil,
          "submit_review" => nil
        })

      assert {:ok, plan} = Normalizer.normalize_task(task)
      assert plan.base_ref == "HEAD"
      assert plan.workspace_policy["branch_name"] == nil
      assert plan.output["draft_pr"] == false
      assert plan.review_profile == "binding"
    end

    test "rejects invalid booleans and blank compatibility strings" do
      assert {:error, {:invalid_field_type, "open_pr"}} =
               Normalizer.normalize_task(Map.put(@legacy_task, "open_pr", "yes"))

      for field <- ~w(repo_path acp_agent base_ref branch_name worktree_base_dir) do
        assert {:error, {:blank_field, ^field}} =
                 Normalizer.normalize_task(Map.put(@legacy_task, field, "  "))
      end
    end

    test "requires every legacy field and validates task without trimming it" do
      for field <- ~w(task repo_path acp_agent) do
        assert {:error, {:missing_field, ^field}} =
                 Normalizer.normalize_task(Map.delete(@legacy_task, field))
      end

      assert {:error, {:blank_field, "task"}} =
               Normalizer.normalize_task(Map.put(@legacy_task, "task", " \n "))

      assert {:error, {:invalid_field_type, "task"}} =
               Normalizer.normalize_task(Map.put(@legacy_task, "task", 42))
    end
  end

  describe "direct plan normalization" do
    test "round-trips a complete string-keyed versioned plan" do
      direct_plan = %{
        "version" => 1,
        "task" => "Add a security regression test",
        "repo_root" => "/workspace/arbor",
        "base_ref" => "main",
        "task_class" => "security_regression",
        "workspace_policy" => %{
          "mode" => "isolated",
          "branch_name" => "test/security-regression",
          "worktree_base_dir" => "/tmp/worktrees"
        },
        "worker" => %{
          "provider" => "grok",
          "model" => "grok-code-fast",
          "permission_mode" => "deny",
          "use_pool" => true,
          "resume_session_id" => "provider-session-123"
        },
        "validation_profile" => "security_regression",
        "review_profile" => "human_required",
        "overlays" => [],
        "rework" => %{"max_cycles" => 1, "stop_conditions" => ["validation_failed"]},
        "budgets" => %{
          "wall_clock_ms" => 600_000,
          "inactivity_timeout_ms" => 120_000,
          "model_cost_usd" => 2.5,
          "parallelism" => 1
        },
        "output" => %{"commit" => true, "draft_pr" => true, "retain_workspace" => true},
        "requested_paths" => ["apps/arbor_security/test/security_regression_test.exs"]
      }

      assert {:ok, plan} =
               Normalizer.normalize_task(%{"kind" => "coding_change", "plan" => direct_plan})

      assert Plan.to_map(plan) == direct_plan
    end

    test "returns Plan validation errors without losing detail" do
      task = %{
        "kind" => "coding_change",
        "plan" => %{
          "task" => "test",
          "repo_root" => "/workspace/arbor",
          "worker" => %{"provider" => "grok"},
          "authorization" => true
        }
      }

      assert {:error, {:unknown_fields, ["authorization"]}} =
               Normalizer.normalize_task(task)
    end

    test "rejects the legacy-only none review profile for direct planner input" do
      task = %{
        "kind" => "coding_change",
        "plan" => %{
          "task" => "test",
          "repo_root" => "/workspace/arbor",
          "worker" => %{"provider" => "grok"},
          "review_profile" => "none"
        }
      }

      assert {:error, {:coding_plan_review_profile_not_allowed, "none"}} =
               Normalizer.normalize_task(task)
    end

    test "accepts binding and human-required direct review profiles" do
      for review_profile <- ~w(binding human_required) do
        task = %{
          "kind" => "coding_change",
          "plan" => %{
            "task" => "test",
            "repo_root" => "/workspace/arbor",
            "worker" => %{"provider" => "grok"},
            "review_profile" => review_profile
          }
        }

        assert {:ok, plan} = Normalizer.normalize_task(task)
        assert plan.review_profile == review_profile
      end
    end

    test "does not coerce direct plan keys or values" do
      atom_key_plan = %{
        "kind" => "coding_change",
        "plan" => %{:task => "test", "repo_root" => "/tmp", "worker" => %{"provider" => "grok"}}
      }

      assert {:error, {:non_json_task, :nested_non_string_key}} =
               Normalizer.normalize_task(atom_key_plan)

      assert {:error, {:invalid_field, "version", {:expected, 1, "1"}}} =
               Normalizer.normalize_task(%{
                 "kind" => "coding_change",
                 "plan" => %{
                   "version" => "1",
                   "task" => "test",
                   "repo_root" => "/tmp",
                   "worker" => %{"provider" => "grok"}
                 }
               })
    end
  end

  describe "fail-closed boundary" do
    test "rejects mixed and unknown task shapes" do
      assert {:error, :mixed_task_shape} =
               Normalizer.normalize_task(%{
                 "kind" => "coding_change",
                 "plan" => %{},
                 "task" => "legacy"
               })

      assert {:error, {:unknown_task_key, "unexpected"}} =
               Normalizer.normalize_task(Map.put(@legacy_task, "unexpected", true))

      assert {:error, {:unknown_task_key, "unexpected"}} =
               Normalizer.normalize_task(%{
                 "kind" => "coding_change",
                 "plan" => %{},
                 "unexpected" => true
               })
    end

    test "forbidden task keys take precedence over unknown keys" do
      for key <- @authority_keys do
        task = @legacy_task |> Map.put("zzz_unknown", true) |> Map.put(key, "attacker-data")

        assert {:error, {:forbidden_task_key, ^key}} = Normalizer.normalize_task(task)
      end
    end

    test "rejects top-level and recursive non-JSON values" do
      assert {:error, :invalid_task} = Normalizer.normalize_task([{"kind", "coding_change"}])
      assert {:error, :invalid_task} = Normalizer.normalize_task(%URI{})

      assert {:error, {:non_json_task, :non_string_key}} =
               Normalizer.normalize_task(%{kind: "coding_change"})

      invalid_values = [
        :atom,
        self(),
        fn -> :ok end,
        make_ref(),
        {:tuple, "value"},
        %URI{},
        [name: "keyword"],
        [1 | 2]
      ]

      for value <- invalid_values do
        assert {:error, {:non_json_task, _reason}} =
                 @legacy_task
                 |> Map.put("task", "test")
                 |> Map.put("extra", value)
                 |> Normalizer.normalize_task()
      end

      assert {:error, {:non_json_task, :nested_non_string_key}} =
               @legacy_task
               |> Map.put("extra", %{:atom => "key"})
               |> Normalizer.normalize_task()
    end

    test "rejects ports as non-JSON values" do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      assert {:error, {:non_json_task, :port_not_json}} =
               @legacy_task
               |> Map.put("extra", port)
               |> Normalizer.normalize_task()
    end

    test "requires the exact supported kind" do
      assert {:error, :missing_task_kind} =
               Normalizer.normalize_task(Map.delete(@legacy_task, "kind"))

      assert {:error, {:unsupported_task_kind, "other"}} =
               Normalizer.normalize_task(%{@legacy_task | "kind" => "other"})

      assert {:error, {:unsupported_task_kind, " coding_change "}} =
               Normalizer.normalize_task(%{@legacy_task | "kind" => " coding_change "})

      assert {:error, {:invalid_field_type, "kind"}} =
               Normalizer.normalize_task(%{@legacy_task | "kind" => 1})
    end

    test "rejects invalid UTF-8 before plan construction" do
      assert {:error, {:non_json_task, :invalid_utf8_string}} =
               Normalizer.normalize_task(%{@legacy_task | "task" => <<255>>})

      assert {:error, {:non_json_task, :invalid_utf8_key}} =
               Normalizer.normalize_task(Map.put(@legacy_task, <<255>>, true))
    end

    test "normalized plans contain no authority or graph-control keys" do
      assert {:ok, plan} = Normalizer.normalize_task(@legacy_task)
      plan_keys = plan |> Plan.to_map() |> Map.keys()

      assert MapSet.disjoint?(MapSet.new(plan_keys), MapSet.new(@authority_keys))
      assert {:ok, _json} = plan |> Plan.to_map() |> Jason.encode()
    end
  end
end
