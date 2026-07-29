defmodule Arbor.ActionsTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Actions

  alias Arbor.Actions.TestFixtures.{
    BoundNestedInnerAction,
    ContradictoryWriteReplayActionForActionsTest
  }

  defmodule NoObjectCodeAction do
    @moduledoc false

    def to_tool do
      %{
        name: "no_object_code",
        description: "Loaded only from the test source",
        parameters_schema: %{"type" => "object"}
      }
    end
  end

  defmodule ReadOnlyReplayAction do
    @moduledoc false
    def execution_idempotency, do: :read_only
  end

  defmodule IdempotentReplayAction do
    @moduledoc false
    def execution_idempotency, do: :idempotent
  end

  defmodule KeyedReplayAction do
    @moduledoc false
    def execution_idempotency, do: :idempotent_with_key
  end

  defmodule SideEffectingReplayAction do
    @moduledoc false
    def execution_idempotency, do: :side_effecting
  end

  defmodule InvalidReplayAction do
    @moduledoc false
    def execution_idempotency, do: "read_only"
  end

  defmodule RaisingReplayAction do
    @moduledoc false
    def execution_idempotency, do: raise("invalid replay declaration")
  end

  defmodule ThrowingReplayAction do
    @moduledoc false
    def execution_idempotency, do: throw(:invalid_replay_declaration)
  end

  describe "list_actions/0" do
    test "returns actions organized by category" do
      actions = Actions.list_actions()

      assert Map.has_key?(actions, :shell)
      assert Map.has_key?(actions, :file)
      assert Map.has_key?(actions, :git)

      assert Arbor.Actions.Shell.Execute in actions.shell
      assert Arbor.Actions.File.Read in actions.file
      assert Arbor.Actions.Git.Status in actions.git
    end
  end

  describe "all_actions/0" do
    test "returns flat list of all action modules" do
      actions = Actions.all_actions()

      assert is_list(actions)
      assert actions != []
      assert Arbor.Actions.Shell.Execute in actions
      assert Arbor.Actions.File.Read in actions
      assert Arbor.Actions.Git.Status in actions
    end
  end

  test "coding design admission limit is exposed through the public facade" do
    assert Actions.coding_design_max_bytes() ==
             Arbor.Contracts.Coding.DesignArtifactDescriptor.max_bytes()

    assert Actions.coding_design_max_bytes() == 32_768
  end

  describe "runtime_descriptor/1" do
    test "binds exact Jido name, module, loaded BEAM, resource, and egress declarations" do
      module = Arbor.Actions.File.Read
      assert {:ok, descriptor} = Actions.runtime_descriptor(module)
      assert {^module, beam, _filename} = :code.get_object_code(module)

      assert descriptor == %{
               "name" => "file_read",
               "module" => Atom.to_string(module),
               "beam_sha256" =>
                 beam |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
               "resource_uri" => "arbor://fs/read",
               "effect_class" => "read",
               "execution_idempotency" => "side_effecting",
               "egress_declared" => false,
               "egress_tier_resolver" => false,
               "egress_destination_resolver" => false
             }

      assert {:ok, _json} = Jason.encode(descriptor)
    end

    test "security regression: modules without retrievable BEAM object code fail closed" do
      assert :error = :code.get_object_code(NoObjectCodeAction)
      assert {:error, :action_beam_unavailable} = Actions.runtime_descriptor(NoObjectCodeAction)
    end

    test "security regression: non-journaled write declarations are rejected" do
      assert Actions.execution_idempotency(ContradictoryWriteReplayActionForActionsTest) ==
               :side_effecting

      assert {:error, :execution_idempotency_effect_class_conflict} =
               Actions.runtime_descriptor(ContradictoryWriteReplayActionForActionsTest)
    end

    test "regression: legacy runtime bindings ignore additive replay metadata" do
      assert {:ok, current} = Actions.runtime_descriptor(BoundNestedInnerAction)
      legacy = Map.delete(current, "execution_idempotency")
      bindings = %{legacy["name"] => legacy}
      manifest = %{"actions" => [legacy]}

      assert {:ok, manifest_digest} = Actions.execution_binding_digest(manifest)
      assert {:ok, bindings_digest} = Actions.execution_binding_digest(bindings)

      context = %{
        execution_manifest: manifest,
        execution_manifest_digest: manifest_digest,
        pinned_action_bindings: bindings,
        pinned_action_bindings_digest: bindings_digest,
        test_pid: self()
      }

      assert {:ok, %{inner: true}} =
               Actions.execute_action(BoundNestedInnerAction, %{}, context)

      assert_receive :bound_nested_inner_executed
    end
  end

  describe "execution_idempotency/1" do
    test "accepts only the closed replay classes" do
      assert Actions.execution_idempotency(ReadOnlyReplayAction) == :read_only
      assert Actions.execution_idempotency(IdempotentReplayAction) == :idempotent
      assert Actions.execution_idempotency(KeyedReplayAction) == :idempotent_with_key
      assert Actions.execution_idempotency(SideEffectingReplayAction) == :side_effecting
    end

    test "missing, invalid, raising, throwing, unavailable, and unresolved declarations fail closed" do
      assert Actions.execution_idempotency(Arbor.Actions.File.Read) == :side_effecting
      assert Actions.execution_idempotency(InvalidReplayAction) == :side_effecting
      assert Actions.execution_idempotency(RaisingReplayAction) == :side_effecting
      assert Actions.execution_idempotency(ThrowingReplayAction) == :side_effecting
      assert Actions.execution_idempotency(Arbor.Actions.DefinitelyMissing) == :side_effecting
      assert Actions.execution_idempotency("definitely_missing_action") == :side_effecting
      assert Actions.execution_idempotency(%{}) == :side_effecting
    end
  end

  describe "execution_dependencies/1" do
    test "absent declarations normalize to an empty sorted list" do
      assert {:ok, []} = Actions.execution_dependencies(Arbor.Actions.File.Read)
      assert {:ok, []} = Actions.execution_dependencies(Arbor.Actions.Git.Commit)
    end

    test "ReviewedCommit declares git_commit deterministically" do
      assert {:ok, ["git_commit"]} =
               Actions.execution_dependencies(Arbor.Actions.Coding.ReviewedCommit)

      assert Arbor.Actions.Coding.ReviewedCommit.execution_dependencies() == [
               Arbor.Actions.Git.Commit
             ]
    end

    test "invalid dependency declarations fail closed" do
      defmodule InvalidDependenciesShape do
        def to_tool do
          %{name: "invalid_dependencies_shape", description: "x", parameters_schema: %{}}
        end

        def execution_dependencies, do: :not_a_list
      end

      defmodule InvalidDependenciesEntry do
        def to_tool do
          %{name: "invalid_dependencies_entry", description: "x", parameters_schema: %{}}
        end

        def execution_dependencies, do: ["git_commit"]
      end

      assert {:error, :invalid_execution_dependencies} =
               Actions.execution_dependencies(InvalidDependenciesShape)

      assert {:error, :invalid_execution_dependencies} =
               Actions.execution_dependencies(InvalidDependenciesEntry)
    end

    test "ensure_loads declared dependency modules before reading their action names" do
      leaf_source = """
      defmodule Arbor.Actions.TestFixtures.EnsureLoadDepLeaf do
        def to_tool do
          %{name: "ensure_load_dep_leaf", description: "x", parameters_schema: %{}}
        end
      end
      """

      root_source = """
      defmodule Arbor.Actions.TestFixtures.EnsureLoadDepRoot do
        def to_tool do
          %{name: "ensure_load_dep_root", description: "x", parameters_schema: %{}}
        end

        def execution_dependencies, do: [Arbor.Actions.TestFixtures.EnsureLoadDepLeaf]
      end
      """

      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbor-ensure-load-deps-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      [{leaf, leaf_beam}] = Code.compile_string(leaf_source)
      [{root, _root_beam}] = Code.compile_string(root_source)

      on_exit(fn ->
        _ = :code.del_path(String.to_charlist(tmp))

        for module <- [root, leaf] do
          _ = :code.purge(module)
          _ = :code.delete(module)
          _ = :code.purge(module)
        end

        File.rm_rf(tmp)
      end)

      leaf_beam_path =
        Path.join(tmp, "Elixir.Arbor.Actions.TestFixtures.EnsureLoadDepLeaf.beam")

      File.write!(leaf_beam_path, leaf_beam)
      true = :code.add_patha(String.to_charlist(tmp))

      # delete/1 demotes current→old; purge/1 removes old. Two-step unload so
      # the next ensure_loaded must re-read the on-disk BEAM.
      _ = :code.purge(leaf)
      true = :code.delete(leaf)
      _ = :code.purge(leaf)
      refute :code.is_loaded(leaf)

      assert {:ok, ["ensure_load_dep_leaf"]} = Actions.execution_dependencies(root)
      assert {:file, _path} = :code.is_loaded(leaf)
    end

    test "unavailable declared dependency modules fail closed" do
      defmodule UnavailableDepRoot do
        def to_tool do
          %{name: "unavailable_dep_root", description: "x", parameters_schema: %{}}
        end

        def execution_dependencies, do: [Arbor.Actions.TestFixtures.DefinitelyMissingDependency]
      end

      assert {:error, :invalid_execution_dependencies} =
               Actions.execution_dependencies(UnavailableDepRoot)
    end
  end

  describe "reviewed_pipeline/1" do
    test "returns the packaged code-review council artifact through the public facade" do
      assert {:ok, pipeline} = Actions.reviewed_pipeline("code_review_council")
      assert pipeline.id == "code_review_council"
      assert pipeline.source_id == "arbor_actions:priv/pipelines/code-review-council.dot"

      assert pipeline.path ==
               Application.app_dir(:arbor_actions, "priv/pipelines/code-review-council.dot")

      assert pipeline.source =~ "digraph code_review_council"
      # Reviewers expose the terminal submit tool and mark it terminal.
      assert pipeline.source =~ "coding_submit_review_report"
      assert pipeline.source =~ ~s(terminal_tools="coding_submit_review_report")
      assert pipeline.source =~ "review.review_cycle"
      refute pipeline.source =~ "Return ONLY one strict JSON object"
    end

    test "fails closed for an unknown reviewed pipeline" do
      assert {:error, {:unknown_reviewed_pipeline, "unknown_pipeline"}} =
               Actions.reviewed_pipeline("unknown_pipeline")
    end
  end

  describe "all_tools/0" do
    test "returns tool schemas for all actions" do
      tools = Actions.all_tools()

      assert is_list(tools)
      assert tools != []

      # Each tool should be a map with name and parameters_schema (atom keys)
      Enum.each(tools, fn tool ->
        assert is_map(tool)
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :parameters_schema)
      end)
    end

    test "tool names match action names" do
      tools = Actions.all_tools()
      tool_names = Enum.map(tools, & &1[:name])

      assert "shell_execute" in tool_names
      assert "file_read" in tool_names
      assert "git_status" in tool_names
    end
  end

  describe "tools_for_category/1" do
    test "returns tools for shell category" do
      tools = Actions.tools_for_category(:shell)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "shell_execute" in tool_names
      assert "shell_execute_script" in tool_names
    end

    test "returns tools for file category" do
      tools = Actions.tools_for_category(:file)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "file_read" in tool_names
      assert "file_write" in tool_names
    end

    test "returns tools for git category" do
      tools = Actions.tools_for_category(:git)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "git_status" in tool_names
      assert "git_diff" in tool_names
      assert "git_commit" in tool_names
      assert "git_log" in tool_names
      assert "git_pr" in tool_names
    end

    test "returns tools for comms category" do
      tools = Actions.tools_for_category(:comms)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "comms_send_message" in tool_names
      assert "comms_poll_messages" in tool_names
    end

    test "returns empty list for unknown category" do
      tools = Actions.tools_for_category(:unknown)
      assert tools == []
    end
  end

  describe "emit functions" do
    test "emit_started returns :ok" do
      assert :ok = Actions.emit_started(Arbor.Actions.Shell.Execute, %{command: "test"})
    end

    test "emit_started sanitizes sensitive params" do
      # Params with sensitive keys should not crash - sanitization strips them
      assert :ok =
               Actions.emit_started(Arbor.Actions.Shell.Execute, %{
                 command: "test",
                 password: "secret123",
                 secret: "hidden",
                 token: "tok_abc",
                 api_key: "key_xyz",
                 content: "large content"
               })
    end

    test "emit_started handles non-map params" do
      assert :ok = Actions.emit_started(Arbor.Actions.Shell.Execute, "string params")
      assert :ok = Actions.emit_started(Arbor.Actions.Shell.Execute, nil)
    end

    test "emit_completed returns :ok" do
      assert :ok = Actions.emit_completed(Arbor.Actions.Shell.Execute, %{exit_code: 0})
    end

    test "emit_completed truncates large result values" do
      large_value = String.duplicate("x", 600)

      assert :ok =
               Actions.emit_completed(Arbor.Actions.Shell.Execute, %{
                 stdout: large_value,
                 exit_code: 0
               })
    end

    test "emit_completed handles non-map result" do
      assert :ok = Actions.emit_completed(Arbor.Actions.Shell.Execute, "string result")
      assert :ok = Actions.emit_completed(Arbor.Actions.Shell.Execute, 42)
    end

    test "emit_failed returns :ok" do
      assert :ok = Actions.emit_failed(Arbor.Actions.Shell.Execute, "error reason")
    end

    test "emit_failed handles complex error terms" do
      assert :ok = Actions.emit_failed(Arbor.Actions.Shell.Execute, {:error, :timeout})
      assert :ok = Actions.emit_failed(Arbor.Actions.Shell.Execute, %{code: 500, msg: "fail"})
    end
  end
end
