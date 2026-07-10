defmodule Arbor.Contracts.Coding.PlanTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Coding.Plan

  @minimal_attrs %{
    task: "Implement the Phase 4 coding plan contract",
    repo_root: "/workspace/arbor",
    worker: %{provider: "codex"}
  }

  @top_keys ~w(
    base_ref
    budgets
    output
    overlays
    repo_root
    requested_paths
    review_profile
    rework
    task
    task_class
    validation_profile
    version
    worker
    workspace_policy
  )

  describe "new/1 and defaults" do
    test "constructs an enforced plan with complete normalized defaults" do
      assert {:ok, %Plan{} = plan} = Plan.new(@minimal_attrs)

      assert plan.version == 1
      assert plan.task == @minimal_attrs.task
      assert plan.repo_root == "/workspace/arbor"
      assert plan.base_ref == "HEAD"
      assert plan.task_class == "default"

      assert plan.workspace_policy == %{
               "mode" => "isolated",
               "branch_name" => nil,
               "worktree_base_dir" => nil
             }

      assert plan.worker == %{
               "provider" => "codex",
               "model" => nil,
               "permission_mode" => "default"
             }

      assert plan.validation_profile == "default"
      assert plan.review_profile == "binding"
      assert plan.overlays == []
      assert plan.rework == %{"max_cycles" => 2, "stop_conditions" => []}

      assert plan.budgets == %{
               "wall_clock_ms" => 900_000,
               "inactivity_timeout_ms" => 300_000,
               "model_cost_usd" => nil,
               "parallelism" => 1
             }

      assert plan.output == %{
               "commit" => true,
               "draft_pr" => false,
               "retain_workspace" => true
             }

      assert plan.requested_paths == []
      assert Plan.schema_version() == 1
    end

    test "accepts fully string-keyed JSON input" do
      attrs = %{
        "version" => 1,
        "task" => "Update docs",
        "repo_root" => "/workspace/arbor",
        "base_ref" => "main",
        "task_class" => "docs_only",
        "workspace_policy" => %{
          "mode" => "isolated",
          "branch_name" => "docs/plan",
          "worktree_base_dir" => "/tmp/worktrees"
        },
        "worker" => %{
          "provider" => "grok",
          "model" => "grok-code-fast",
          "permission_mode" => "deny"
        },
        "validation_profile" => "docs_only",
        "review_profile" => "human_required",
        "overlays" => ["contract_change"],
        "rework" => %{
          "max_cycles" => 1,
          "stop_conditions" => ["review_rejected"]
        },
        "budgets" => %{
          "wall_clock_ms" => 600_000,
          "inactivity_timeout_ms" => 120_000,
          "model_cost_usd" => 5.25,
          "parallelism" => 2
        },
        "output" => %{
          "commit" => true,
          "draft_pr" => true,
          "retain_workspace" => true
        },
        "requested_paths" => ["docs/plan.md"]
      }

      assert {:ok, plan} = Plan.new(attrs)
      assert Plan.to_map(plan) == attrs
    end

    test "accepts keyword objects and normalizes known enum atoms" do
      attrs = [
        task: "Add a contract",
        repo_root: "/workspace/arbor",
        task_class: :contract_change,
        workspace_policy: [mode: :isolated, branch_name: "feature/plan"],
        worker: [provider: "codex", model: "gpt-5", permission_mode: :deny],
        validation_profile: :contract_change,
        review_profile: :human_required,
        rework: [max_cycles: 0, stop_conditions: [:declined]],
        budgets: [parallelism: 1],
        output: [draft_pr: true]
      ]

      assert {:ok, plan} = Plan.new(attrs)
      assert plan.task_class == "contract_change"
      assert plan.workspace_policy["mode"] == "isolated"
      assert plan.worker["permission_mode"] == "deny"
      assert plan.validation_profile == "contract_change"
      assert plan.review_profile == "human_required"
      assert plan.rework == %{"max_cycles" => 0, "stop_conditions" => ["declined"]}
      assert plan.output["draft_pr"]
    end

    test "rejects non-object input and missing required fields" do
      assert {:error, {:invalid_object, "plan"}} = Plan.new("not an object")
      assert {:error, {:missing_field, "task"}} = Plan.new(Map.delete(@minimal_attrs, :task))

      assert {:error, {:missing_field, "repo_root"}} =
               Plan.new(Map.delete(@minimal_attrs, :repo_root))

      assert {:error, {:missing_field, "worker"}} =
               Plan.new(Map.delete(@minimal_attrs, :worker))

      assert {:error, {:missing_field, "worker.provider"}} =
               Plan.new(%{@minimal_attrs | worker: %{}})
    end
  end

  describe "version and profile validation" do
    test "requires integer schema version 1" do
      for version <- [0, 2, "1", nil] do
        assert {:error, {:invalid_field, "version", _}} =
                 Plan.new(Map.put(@minimal_attrs, :version, version))
      end
    end

    test "requires nonblank valid task, repo root, and base ref strings" do
      for {field, value} <- [task: " ", repo_root: "", base_ref: "\t", task: 123] do
        assert {:error, {:invalid_field, path, _}} =
                 Plan.new(Map.put(@minimal_attrs, field, value))

        assert path == Atom.to_string(field)
      end
    end

    test "accepts every known task and validation profile" do
      profiles = ~w(
        default
        security_regression
        contract_change
        frontend_visual
        docs_only
        cross_app
        database_migration
      )

      for profile <- profiles do
        attrs =
          @minimal_attrs
          |> Map.put(:task_class, profile)
          |> Map.put(:validation_profile, profile)

        assert {:ok, plan} = Plan.new(attrs)
        assert plan.task_class == profile
        assert plan.validation_profile == profile
      end
    end

    test "rejects unknown task, validation, and review profiles" do
      for {field, value} <- [
            task_class: "arbitrary",
            validation_profile: "skip_everything",
            review_profile: "advisory"
          ] do
        assert {:error, {:invalid_field, path, {:expected_one_of, _, ^value}}} =
                 Plan.new(Map.put(@minimal_attrs, field, value))

        assert path == Atom.to_string(field)
      end
    end

    test "preserves review_profile none for submit_review=false compatibility" do
      assert {:ok, plan} = Plan.new(Map.put(@minimal_attrs, :review_profile, :none))

      map = Plan.to_map(plan)
      assert plan.review_profile == "none"
      assert map["review_profile"] == "none"
      refute Map.has_key?(map, "submit_review")
    end
  end

  describe "strict object keys" do
    test "rejects unknown top-level fields, including embedded authority" do
      forbidden = ~w(
        graph
        graph_path
        action
        actions
        capabilities
        identity
        agent_id
        principal_id
        authorization
        signer
        submit_review
      )

      for field <- forbidden do
        attrs = Map.put(@minimal_attrs, field, "attacker-controlled")
        assert {:error, {:unknown_fields, [^field]}} = Plan.new(attrs)
      end
    end

    test "rejects unknown fields in every nested object" do
      cases = [
        {:workspace_policy, %{mode: "isolated", principal_id: "agent_evil"},
         "workspace_policy.principal_id"},
        {:worker, %{provider: "codex", capabilities: ["all"]}, "worker.capabilities"},
        {:rework, %{max_cycles: 1, graph: "digraph"}, "rework.graph"},
        {:budgets, %{parallelism: 1, authorization: false}, "budgets.authorization"},
        {:output, %{commit: true, retain_workspace: true, merge: true}, "output.merge"}
      ]

      for {field, value, expected_path} <- cases do
        assert {:error, {:unknown_fields, [^expected_path]}} =
                 Plan.new(Map.put(@minimal_attrs, field, value))
      end
    end

    test "rejects duplicate atom/string aliases at the top level" do
      attrs = Map.put(@minimal_attrs, "task", "shadowed task")
      assert {:error, {:duplicate_fields, ["task"]}} = Plan.new(attrs)
    end

    test "rejects repeated keyword keys before they can be overwritten" do
      attrs = [
        task: "first",
        task: "second",
        repo_root: "/workspace/arbor",
        worker: [provider: "codex"]
      ]

      assert {:error, {:duplicate_fields, ["task"]}} = Plan.new(attrs)

      attrs = [
        task: "work",
        repo_root: "/workspace/arbor",
        worker: [provider: "codex", provider: "grok"]
      ]

      assert {:error, {:duplicate_fields, ["worker.provider"]}} = Plan.new(attrs)
    end

    test "rejects duplicate atom/string aliases in every nested object" do
      cases = [
        {:workspace_policy, %{:mode => "isolated", "mode" => "isolated"},
         "workspace_policy.mode"},
        {:worker, %{:provider => "codex", "provider" => "grok"}, "worker.provider"},
        {:rework, %{:max_cycles => 1, "max_cycles" => 2}, "rework.max_cycles"},
        {:budgets, %{:parallelism => 1, "parallelism" => 2}, "budgets.parallelism"},
        {:output, %{:commit => true, "commit" => true}, "output.commit"}
      ]

      for {field, value, expected_path} <- cases do
        assert {:error, {:duplicate_fields, [^expected_path]}} =
                 Plan.new(Map.put(@minimal_attrs, field, value))
      end
    end
  end

  describe "workspace and worker policy" do
    test "allows only isolated workspaces and optional nonblank strings" do
      assert {:ok, plan} =
               Plan.new(
                 Map.put(@minimal_attrs, :workspace_policy, %{
                   mode: :isolated,
                   branch_name: nil,
                   worktree_base_dir: "/tmp/arbor"
                 })
               )

      assert plan.workspace_policy["mode"] == "isolated"
      assert plan.workspace_policy["branch_name"] == nil
      assert plan.workspace_policy["worktree_base_dir"] == "/tmp/arbor"

      assert {:error, {:invalid_field, "workspace_policy.mode", _}} =
               Plan.new(Map.put(@minimal_attrs, :workspace_policy, %{mode: "in_place"}))

      for field <- [:branch_name, :worktree_base_dir] do
        assert {:error, {:invalid_field, path, _}} =
                 Plan.new(
                   Map.put(@minimal_attrs, :workspace_policy, %{field => " ", mode: "isolated"})
                 )

        assert path == "workspace_policy.#{field}"
      end
    end

    test "requires a provider and permits only default or deny permission modes" do
      assert {:ok, plan} =
               Plan.new(
                 Map.put(@minimal_attrs, :worker, %{
                   provider: "codex",
                   model: "gpt-5",
                   permission_mode: :deny
                 })
               )

      assert plan.worker == %{
               "provider" => "codex",
               "model" => "gpt-5",
               "permission_mode" => "deny"
             }

      for provider <- [nil, "", " ", :codex] do
        assert {:error, {:invalid_field, "worker.provider", _}} =
                 Plan.new(Map.put(@minimal_attrs, :worker, %{provider: provider}))
      end

      for mode <- ["bypass", "bypassPermissions", :bypass, "accept_edits"] do
        assert {:error, {:invalid_field, "worker.permission_mode", _}} =
                 Plan.new(
                   Map.put(@minimal_attrs, :worker, %{
                     provider: "codex",
                     permission_mode: mode
                   })
                 )
      end
    end

    test "rejects blank or non-string model overrides" do
      for model <- ["", " ", :default] do
        assert {:error, {:invalid_field, "worker.model", _}} =
                 Plan.new(Map.put(@minimal_attrs, :worker, %{provider: "codex", model: model}))
      end
    end
  end

  describe "overlays and rework" do
    test "deduplicates and lexically sorts known non-default overlays" do
      attrs =
        Map.put(@minimal_attrs, :overlays, [
          :security_regression,
          "docs_only",
          "contract_change",
          "security_regression"
        ])

      assert {:ok, plan} = Plan.new(attrs)
      assert plan.overlays == ["contract_change", "docs_only", "security_regression"]
    end

    test "rejects default, unknown, and non-list overlays" do
      for overlays <- [["default"], ["unknown"], "docs_only"] do
        assert {:error, {:invalid_field, "overlays" <> _, _}} =
                 Plan.new(Map.put(@minimal_attrs, :overlays, overlays))
      end
    end

    test "bounds rework cycles from zero through two" do
      for cycles <- 0..2 do
        assert {:ok, plan} =
                 Plan.new(Map.put(@minimal_attrs, :rework, %{max_cycles: cycles}))

        assert plan.rework["max_cycles"] == cycles
      end

      for cycles <- [-1, 3, 1.5, "2"] do
        assert {:error, {:invalid_field, "rework.max_cycles", _}} =
                 Plan.new(Map.put(@minimal_attrs, :rework, %{max_cycles: cycles}))
      end
    end

    test "accepts only fixed stop conditions and canonicalizes their order" do
      conditions = [
        :validation_failed,
        "declined",
        "review_rejected",
        "no_changes",
        "declined"
      ]

      assert {:ok, plan} =
               Plan.new(
                 Map.put(@minimal_attrs, :rework, %{
                   max_cycles: 2,
                   stop_conditions: conditions
                 })
               )

      assert plan.rework["stop_conditions"] ==
               ~w(declined no_changes review_rejected validation_failed)

      assert {:error, {:invalid_field, "rework.stop_conditions[0]", _}} =
               Plan.new(
                 Map.put(@minimal_attrs, :rework, %{stop_conditions: ["run_arbitrary_dot"]})
               )

      assert {:error, {:invalid_field, "rework.stop_conditions", _}} =
               Plan.new(Map.put(@minimal_attrs, :rework, %{stop_conditions: "declined"}))
    end
  end

  describe "budgets and output" do
    test "accepts bounded budget values and normalizes cost to a JSON number" do
      attrs =
        Map.put(@minimal_attrs, :budgets, %{
          wall_clock_ms: 86_400_000,
          inactivity_timeout_ms: 3_600_000,
          model_cost_usd: 100,
          parallelism: 8
        })

      assert {:ok, plan} = Plan.new(attrs)
      assert plan.budgets["wall_clock_ms"] == 86_400_000
      assert plan.budgets["inactivity_timeout_ms"] == 3_600_000
      assert plan.budgets["model_cost_usd"] == 100.0
      assert plan.budgets["parallelism"] == 8
    end

    test "rejects zero, negative, wrong-type, and over-limit budgets" do
      cases = [
        {:wall_clock_ms, 0},
        {:wall_clock_ms, 9_999},
        {:wall_clock_ms, 86_400_001},
        {:inactivity_timeout_ms, -1},
        {:inactivity_timeout_ms, 9_999},
        {:inactivity_timeout_ms, 3_600_001},
        {:model_cost_usd, 0},
        {:model_cost_usd, -0.1},
        {:model_cost_usd, 100.01},
        {:parallelism, 0},
        {:parallelism, 9},
        {:parallelism, 1.5}
      ]

      for {field, value} <- cases do
        assert {:error, {:invalid_field, path, _}} =
                 Plan.new(Map.put(@minimal_attrs, :budgets, %{field => value}))

        assert path == "budgets.#{field}"
      end
    end

    test "allows an omitted or nil model cost cap" do
      assert {:ok, defaulted} = Plan.new(@minimal_attrs)
      assert defaulted.budgets["model_cost_usd"] == nil

      assert {:ok, explicit_nil} =
               Plan.new(Map.put(@minimal_attrs, :budgets, %{model_cost_usd: nil}))

      assert explicit_nil.budgets["model_cost_usd"] == nil
    end

    test "requires commit and workspace retention while allowing draft PR selection" do
      assert {:ok, plan} = Plan.new(Map.put(@minimal_attrs, :output, %{draft_pr: true}))
      assert plan.output["commit"]
      assert plan.output["draft_pr"]
      assert plan.output["retain_workspace"]

      for {field, value} <- [commit: false, retain_workspace: false, commit: "true"] do
        assert {:error, {:invalid_field, path, _}} =
                 Plan.new(Map.put(@minimal_attrs, :output, %{field => value}))

        assert path == "output.#{field}"
      end

      assert {:error, {:invalid_field, "output.draft_pr", _}} =
               Plan.new(Map.put(@minimal_attrs, :output, %{draft_pr: "true"}))
    end
  end

  describe "requested paths" do
    test "accepts relative safe paths, then deduplicates and sorts them" do
      paths = [
        "test/arbor/contracts/coding/plan_test.exs",
        ".formatter.exs",
        "apps/arbor_contracts/lib/arbor/contracts/coding/plan.ex",
        "test/arbor/contracts/coding/plan_test.exs"
      ]

      assert {:ok, plan} = Plan.new(Map.put(@minimal_attrs, :requested_paths, paths))

      assert plan.requested_paths == [
               ".formatter.exs",
               "apps/arbor_contracts/lib/arbor/contracts/coding/plan.ex",
               "test/arbor/contracts/coding/plan_test.exs"
             ]
    end

    test "rejects absolute, blank, NUL, dot, and traversal paths" do
      invalid_paths = [
        "",
        " ",
        ".",
        "..",
        "/etc/passwd",
        "lib/../secret.ex",
        "lib/./plan.ex",
        "lib\\..\\secret.ex",
        "C:\\Windows\\system.ini",
        "\\\\server\\share\\file",
        "\\rooted\\file",
        "lib/plan.ex" <> <<0>> <> ".bak"
      ]

      for path <- invalid_paths do
        assert {:error, {:invalid_field, "requested_paths[0]", _}} =
                 Plan.new(Map.put(@minimal_attrs, :requested_paths, [path]))
      end
    end

    test "rejects non-string path entries and non-list path collections" do
      assert {:error, {:invalid_field, "requested_paths[0]", _}} =
               Plan.new(Map.put(@minimal_attrs, :requested_paths, [:lib]))

      assert {:error, {:invalid_field, "requested_paths", _}} =
               Plan.new(Map.put(@minimal_attrs, :requested_paths, "lib/plan.ex"))
    end
  end

  describe "to_map/1 and JSON" do
    test "returns only the declared string-keyed JSON fields with normalized defaults" do
      assert {:ok, plan} = Plan.new(@minimal_attrs)
      map = Plan.to_map(plan)

      assert Map.keys(map) |> Enum.sort() == @top_keys
      assert_string_keyed_json(map)

      for forbidden <- ~w(graph actions capabilities identity principal_id authorization signer) do
        refute Map.has_key?(map, forbidden)
      end

      assert map["workspace_policy"]["branch_name"] == nil
      assert map["worker"]["model"] == nil
      assert map["rework"]["max_cycles"] == 2
      assert map["budgets"]["model_cost_usd"] == nil
      assert map["output"]["retain_workspace"] == true
    end

    test "to_map round-trips through Jason without structs, atoms, or dropped defaults" do
      attrs =
        @minimal_attrs
        |> Map.put(:review_profile, :none)
        |> Map.put(:overlays, [:security_regression, :contract_change])
        |> Map.put(:requested_paths, ["lib/plan.ex"])

      assert {:ok, plan} = Plan.new(attrs)
      canonical = Plan.to_map(plan)

      assert {:ok, json} = Jason.encode(canonical)
      assert Jason.decode!(json) == canonical
    end
  end

  defp assert_string_keyed_json(value) when is_map(value) do
    assert Enum.all?(Map.keys(value), &is_binary/1)
    Enum.each(Map.values(value), &assert_string_keyed_json/1)
  end

  defp assert_string_keyed_json(value) when is_list(value) do
    Enum.each(value, &assert_string_keyed_json/1)
  end

  defp assert_string_keyed_json(value) do
    assert is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)
  end
end
