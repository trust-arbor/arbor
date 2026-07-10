defmodule Arbor.Orchestrator.CodingChangePipelineTest do
  @moduledoc """
  Phase 1 structural + deterministic execution tests for coding-change-v1.dot.

  Execution uses a fake ActionsExecutor; no real shell, network, ACP, or LLM.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :coding_change_pipeline

  @pipeline_path "apps/arbor_orchestrator/priv/pipelines/coding-change-v1.dot"

  @exec_actions ~w(
    coding_workspace_acquire
    coding_workspace_inspect
    coding_workspace_release
    coding_workspace_committed_change
    acp_start_session
    acp_send_message
    acp_close_session
    mix_compile
    git_commit
    git_pr
    council_review_change
  )

  # ---------------------------------------------------------------------------
  # Fake ActionsExecutor: scripted terminal-path fixtures
  # ---------------------------------------------------------------------------

  defmodule FakeActionsExecutor do
    @moduledoc false

    def execute(name, args, _workdir, _opts) do
      state = Process.get(:coding_change_fake_state)

      if is_nil(state) do
        {:error, "fake executor state missing for #{name}"}
      else
        Agent.update(state, fn s ->
          %{s | calls: s.calls ++ [{name, stringify_keys(args)}]}
        end)

        scenario = Agent.get(state, & &1.scenario)
        counters = Agent.get(state, & &1.counters)

        case dispatch(name, args, scenario, counters, state) do
          {:ok, result} when is_map(result) ->
            {:ok, Jason.encode!(result)}

          other ->
            other
        end
      end
    end

    defp dispatch(name, args, scenario, counters, state) do
      case name do
        "coding_workspace_acquire" ->
          case scenario do
            :acquire_failed ->
              {:error, "acquire rejected"}

            _ ->
              {:ok,
               %{
                 workspace_id: "ws_fixture_1",
                 repo_path:
                   Map.get(args, "repo_path") || Map.get(args, :repo_path) || "/tmp/repo",
                 worktree_path: "/tmp/ws_fixture_1",
                 branch:
                   Map.get(args, "branch_name") || Map.get(args, :branch_name) ||
                     "arbor/coding-agent/fixture",
                 base_commit: "basecommit0001",
                 ownership: "owned",
                 active: true
               }}
          end

        "acp_start_session" ->
          case scenario do
            :worker_open_failed ->
              {:error, "worker open failed"}

            _ ->
              {:ok,
               %{
                 worker_session_id: "acp_worker_fixture_1",
                 session_id: "sess_1",
                 provider: Map.get(args, "provider") || Map.get(args, :provider) || "codex",
                 model: "default",
                 status: "ready",
                 pooled: false
               }}
          end

        "acp_send_message" ->
          implement_response(scenario, counters, state)

        "coding_workspace_inspect" ->
          inspect_response(scenario, counters, state)

        "mix_compile" ->
          validate_response(scenario, counters, state)

        "git_commit" ->
          commit_response(scenario, counters, state)

        "coding_workspace_committed_change" ->
          committed_change_response(scenario)

        "council_review_change" ->
          review_response(scenario, counters, state)

        "git_pr" ->
          pr_response(scenario)

        "acp_close_session" ->
          case scenario do
            :close_failed ->
              {:error, "close session failed"}

            _ ->
              {:ok, %{worker_session_id: "acp_worker_fixture_1", status: "closed"}}
          end

        "coding_workspace_release" ->
          mode = Map.get(args, "mode") || Map.get(args, :mode) || "retain"

          {:ok,
           %{
             workspace_id: "ws_fixture_1",
             status: "retained",
             mode: mode,
             active: false
           }}

        other ->
          {:error, "unexpected action in fixture: #{other}"}
      end
    end

    defp implement_response(scenario, counters, state) do
      n = Map.get(counters, :implement, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :implement, n + 1)} end)

      case scenario do
        :implement_hard_fail ->
          {:error, "implement transport failed"}

        _ ->
          text =
            case {scenario, n} do
              {:declined, _} ->
                Jason.encode!(%{status: "declined", summary: "underspecified"})

              {:no_changes, _} ->
                Jason.encode!(%{status: "implemented", summary: "noop"})

              {:validation_failed, 0} ->
                Jason.encode!(%{status: "implemented", summary: "broken"})

              {:validation_failed, _} ->
                Jason.encode!(%{status: "implemented", summary: "still broken"})

              {:validation_hard_fail, _} ->
                Jason.encode!(%{status: "implemented", summary: "validate boom"})

              {:review_requires_rework, _} ->
                Jason.encode!(%{status: "implemented", summary: "needs review rework"})

              {:rework_exhausted, 0} ->
                Jason.encode!(%{status: "implemented", summary: "first"})

              {:rework_exhausted, _} ->
                Jason.encode!(%{status: "implemented", summary: "after rework"})

              {:review_rejected, _} ->
                Jason.encode!(%{status: "implemented", summary: "rejected path"})

              {:review_failed, _} ->
                Jason.encode!(%{status: "implemented", summary: "review boom"})

              {:committed_change_failed, _} ->
                Jason.encode!(%{status: "implemented", summary: "diff boom"})

              {:commit_hard_fail, _} ->
                Jason.encode!(%{status: "implemented", summary: "commit boom"})

              {:inspect_hard_fail, _} ->
                Jason.encode!(%{status: "implemented", summary: "inspect boom"})

              {:extract_hard_fail, _} ->
                # Invalid JSON so json_extract fails
                "not-json-status"

              {:close_failed, _} ->
                Jason.encode!(%{status: "implemented", summary: "close boom path"})

              {:human_review_required, _} ->
                Jason.encode!(%{status: "implemented", summary: "human"})

              {:pr_failed, _} ->
                Jason.encode!(%{status: "implemented", summary: "pr fail"})

              {:pr_created, _} ->
                Jason.encode!(%{status: "implemented", summary: "pr ok"})

              {:change_committed, _} ->
                Jason.encode!(%{status: "implemented", summary: "committed"})

              {:self_commit_adopt, _} ->
                Jason.encode!(%{status: "implemented", summary: "self committed"})

              _ ->
                Jason.encode!(%{status: "implemented", summary: "default"})
            end

          {:ok, %{text: text, stop_reason: "end_turn", session_id: "sess_1", usage: %{}}}
      end
    end

    defp inspect_response(scenario, counters, state) do
      n = Map.get(counters, :inspect, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :inspect, n + 1)} end)

      case scenario do
        :inspect_hard_fail ->
          {:error, "inspect failed"}

        _ ->
          base = %{
            workspace_id: "ws_fixture_1",
            worktree_path: "/tmp/ws_fixture_1",
            branch: "arbor/coding-agent/fixture",
            base_commit: "basecommit0001",
            ownership: "owned",
            active: true,
            exists: true
          }

          view =
            case scenario do
              :no_changes ->
                Map.merge(base, %{
                  dirty: false,
                  head_commit: "basecommit0001",
                  changed_from_base: false
                })

              :self_commit_adopt ->
                Map.merge(base, %{
                  dirty: false,
                  head_commit: "selfcommit9999",
                  changed_from_base: true
                })

              :declined ->
                Map.merge(base, %{
                  dirty: false,
                  head_commit: "basecommit0001",
                  changed_from_base: false
                })

              _ ->
                Map.merge(base, %{
                  dirty: true,
                  head_commit: "basecommit0001",
                  changed_from_base: true
                })
            end

          {:ok, view}
      end
    end

    defp validate_response(scenario, counters, state) do
      n = Map.get(counters, :validate, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :validate, n + 1)} end)

      case scenario do
        :validation_hard_fail ->
          {:error, "mix compile crashed"}

        _ ->
          passed =
            case {scenario, n} do
              {:validation_failed, _} -> false
              {:rework_exhausted, 0} -> false
              {:rework_exhausted, _} -> true
              _ -> true
            end

          {:ok,
           %{
             path: "/tmp/ws_fixture_1",
             exit_code: if(passed, do: 0, else: 1),
             passed: passed,
             stdout: if(passed, do: "ok", else: "error"),
             stderr: if(passed, do: "", else: "compile failed")
           }}
      end
    end

    defp commit_response(scenario, _counters, _state) do
      case scenario do
        :self_commit_adopt ->
          # Should not be called for clean self-commit adopt path
          {:error, "git_commit must not run on clean self-commit adopt"}

        :commit_hard_fail ->
          {:error, "git commit failed"}

        _ ->
          {:ok,
           %{
             path: "/tmp/ws_fixture_1",
             commit_hash: "commitabc123",
             message: "fixture commit",
             output: "[branch abc] fixture"
           }}
      end
    end

    defp committed_change_response(:committed_change_failed) do
      {:error, "dirty workspace or missing base"}
    end

    defp committed_change_response(_scenario) do
      {:ok,
       %{
         workspace_id: "ws_fixture_1",
         commit_hash: "commitabc123",
         diff: "diff --git a/file.ex b/file.ex\n+hello\n",
         files: ["file.ex"],
         base_ref: "basecommit0001",
         branch: "arbor/coding-agent/fixture",
         worktree_path: "/tmp/ws_fixture_1"
       }}
    end

    defp review_response(scenario, counters, state) do
      n = Map.get(counters, :review, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :review, n + 1)} end)

      case scenario do
        :review_failed ->
          {:error, "council unavailable"}

        :review_rejected ->
          {:ok, review_payload("stop")}

        :human_review_required ->
          {:ok, review_payload("human_review")}

        :review_requires_rework ->
          {:ok, review_payload("rework")}

        :rework_exhausted ->
          # After validation rework, review keeps asking for rework until exhausted
          {:ok, review_payload("rework")}

        _ ->
          {:ok, review_payload("auto_proceed")}
      end
    end

    defp review_payload(tier) do
      %{
        status: "reviewed",
        tier_decision: tier,
        recommendation: if(tier == "stop", do: "reject", else: "revise"),
        human_required: tier == "human_review",
        security_veto: false,
        blast_radius: "low",
        decision: "reviewed"
      }
    end

    defp pr_response(:pr_failed), do: {:error, "scm rejected draft PR"}
    defp pr_response(_), do: {:ok, %{url: "https://example.test/pr/1", number: 1, draft: true}}

    defp stringify_keys(map) when is_map(map) do
      Map.new(map, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_dot do
    path =
      [
        @pipeline_path,
        Path.expand("../../../priv/pipelines/coding-change-v1.dot", __DIR__),
        Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot")
      ]
      |> Enum.find(@pipeline_path, &File.exists?/1)

    File.read!(path)
  end

  defp load_graph do
    assert {:ok, graph} = Arbor.Orchestrator.parse(load_dot())
    graph
  end

  defp run_fixture(scenario, initial_overrides \\ %{}) do
    {:ok, state} =
      Agent.start_link(fn ->
        %{scenario: scenario, calls: [], counters: %{}}
      end)

    Process.put(:coding_change_fake_state, state)

    on_exit(fn ->
      Process.delete(:coding_change_fake_state)
      if Process.alive?(state), do: Agent.stop(state)
    end)

    # Concrete optional acquire keys silence ExecHandler missing-context warnings.
    initial =
      %{
        "task" => "fixture task for #{scenario}",
        "repo_path" => "/tmp/repo",
        "base_ref" => "HEAD",
        "branch_name" => "arbor/coding-agent/fixture",
        "worktree_base_dir" => "/tmp/worktrees",
        "acp_agent" => "codex",
        "open_pr" => "false",
        "submit_review" => "true",
        "session.agent_id" => "agent_fixture",
        "session.task_id" => "task_fixture"
      }
      |> Map.merge(initial_overrides)

    opts = [
      authorization: false,
      actions_executor: FakeActionsExecutor,
      initial_values: initial,
      max_steps: 200,
      sleep_fn: fn _ -> :ok end
    ]

    result = Arbor.Orchestrator.run(load_dot(), opts)
    calls = Agent.get(state, & &1.calls)
    {result, calls}
  end

  defp assert_json_clean_context(context) when is_map(context) do
    Enum.each(context, fn {k, v} ->
      assert is_binary(k) or is_atom(k)
      assert json_clean_value?(v), "context key #{inspect(k)} is not JSON-clean: #{inspect(v)}"
    end)
  end

  defp json_clean_value?(value) do
    case value do
      %{} = map when not is_struct(map) ->
        Enum.all?(map, fn {k, v} -> (is_atom(k) or is_binary(k)) and json_clean_value?(v) end)

      list when is_list(list) ->
        Enum.all?(list, &json_clean_value?/1)

      v when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v) ->
        true

      _ ->
        false
    end
  end

  defp assert_opaque_handles(context) do
    ws = context["workspace_id"] || context[:workspace_id]
    worker = context["worker_session_id"] || context[:worker_session_id]

    if ws do
      assert is_binary(ws)
      refute String.contains?(ws, "#PID")
    end

    if worker do
      assert is_binary(worker)
      refute String.contains?(worker, "#PID")
    end
  end

  defp assert_closed_and_released(calls) do
    names = Enum.map(calls, fn {name, _} -> name end)
    assert "acp_close_session" in names
    assert "coding_workspace_release" in names

    release_args =
      calls
      |> Enum.filter(fn {name, _} -> name == "coding_workspace_release" end)
      |> Enum.map(fn {_, args} -> args end)

    assert Enum.any?(release_args, fn args ->
             mode = args["mode"] || args[:mode]
             mode in ["retain", nil]
           end)
  end

  defp assert_released(calls) do
    assert called?(calls, "coding_workspace_release")
  end

  defp called?(calls, action_name), do: Enum.any?(calls, fn {n, _} -> n == action_name end)

  # ---------------------------------------------------------------------------
  # Structural / compile
  # ---------------------------------------------------------------------------

  describe "coding-change-v1.dot structure" do
    test "parses strictly, compiles typed IR, and has no error diagnostics" do
      dot = load_dot()
      assert {:ok, graph} = Arbor.Orchestrator.parse(dot)

      structural = Arbor.Orchestrator.validate(graph)
      structural_errors = Enum.filter(structural, &(&1.severity == :error))
      assert structural_errors == [], "structural errors: #{inspect(structural_errors)}"

      assert {:ok, compiled} = Arbor.Orchestrator.compile(graph)
      assert compiled.compiled == true

      diagnostics = Arbor.Orchestrator.validate_typed(compiled, [])
      errors = Enum.filter(diagnostics, &(&1.severity == :error))
      assert errors == [], "unexpected error diagnostics: #{inspect(errors)}"
    end

    test "all exec actions resolve and never call coding_produce_reviewable_change" do
      graph = load_graph()

      exec_actions =
        graph.nodes
        |> Map.values()
        |> Enum.filter(
          &(Map.get(&1.attrs, "type") == "exec" and Map.get(&1.attrs, "target") == "action")
        )
        |> Enum.map(&Map.get(&1.attrs, "action"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert Enum.sort(@exec_actions) == exec_actions
      refute "coding_produce_reviewable_change" in exec_actions
      refute "coding.produce_reviewable_change" in exec_actions

      # Resolve each name the same way ActionsExecutor does
      for action <- exec_actions do
        assert {:ok, mod} = Arbor.Actions.name_to_module(action),
               "action #{action} does not resolve"

        assert is_atom(mod)
      end
    end

    test "acquire precedes mutation and cleanup uses retain release" do
      graph = load_graph()
      assert graph.nodes["acquire_workspace"]
      assert graph.nodes["release_workspace"]
      assert graph.nodes["close_worker"]

      release = graph.nodes["release_workspace"]
      assert release.attrs["action"] == "coding_workspace_release"

      # Validation is top-level mix_compile (not nested shell)
      validate = graph.nodes["validate"]
      assert validate.attrs["action"] == "mix_compile"

      # Commit path has dirty vs adopt split
      assert graph.nodes["commit_change"]
      assert graph.nodes["adopt_head_commit"]

      # No production prefer_rework_exhausted switch
      refute Map.has_key?(graph.nodes, "status_review_requires_rework")
      assert graph.nodes["status_rework_exhausted"]
      assert graph.nodes["legacy_status_review_requires_rework"]

      # Bind materialization to the exact commit produced by this run.
      load = graph.nodes["load_committed_change"]
      assert load.attrs["context_keys"] == "workspace_id,commit"
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic terminal-path fixtures
  # ---------------------------------------------------------------------------

  describe "terminal path fixtures" do
    test "declined closes worker and retains workspace" do
      assert {{:ok, result}, calls} = run_fixture(:declined)
      assert result.context["status"] == "declined"
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
      assert_opaque_handles(result.context)
      refute called?(calls, "mix_compile")
      refute called?(calls, "git_commit")
    end

    test "no_changes when HEAD equals base and clean" do
      assert {{:ok, result}, calls} = run_fixture(:no_changes)
      assert result.context["status"] == "no_changes"
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
      refute called?(calls, "mix_compile")
      refute called?(calls, "git_commit")
    end

    test "validation_failed after bounded rework" do
      assert {{:ok, result}, calls} = run_fixture(:validation_failed)
      assert result.context["status"] == "validation_failed"
      assert_closed_and_released(calls)

      validate_calls = Enum.count(calls, fn {n, _} -> n == "mix_compile" end)
      implement_calls = Enum.count(calls, fn {n, _} -> n == "acp_send_message" end)
      assert validate_calls >= 2
      assert implement_calls >= 2
      refute called?(calls, "git_commit")
    end

    test "rework_exhausted when review revise exhausts budget with legacy_status" do
      assert {{:ok, result}, calls} = run_fixture(:review_requires_rework)
      assert result.context["status"] == "rework_exhausted"
      assert result.context["legacy_status"] == "review_requires_rework"
      assert_closed_and_released(calls)
      assert called?(calls, "council_review_change")
    end

    test "rework_exhausted after validation rework then review rework" do
      assert {{:ok, result}, calls} = run_fixture(:rework_exhausted)
      assert result.context["status"] == "rework_exhausted"
      assert result.context["legacy_status"] == "review_requires_rework"
      assert_closed_and_released(calls)
    end

    test "review_rejected" do
      assert {{:ok, result}, calls} = run_fixture(:review_rejected)
      assert result.context["status"] == "review_rejected"
      assert_closed_and_released(calls)
      refute called?(calls, "git_pr")
    end

    test "review_failed on council error" do
      assert {{:ok, result}, calls} = run_fixture(:review_failed)
      assert result.context["status"] == "review_failed"
      assert_closed_and_released(calls)
    end

    test "human_review_required without PR" do
      assert {{:ok, result}, calls} = run_fixture(:human_review_required)
      assert result.context["status"] == "human_review_required"
      assert_closed_and_released(calls)
      refute called?(calls, "git_pr")
    end

    test "pr_failed" do
      assert {{:ok, result}, calls} = run_fixture(:pr_failed, %{"open_pr" => "true"})
      assert result.context["status"] == "pr_failed"
      assert_closed_and_released(calls)
      assert called?(calls, "git_pr")
    end

    test "pr_created" do
      assert {{:ok, result}, calls} = run_fixture(:pr_created, %{"open_pr" => "true"})
      assert result.context["status"] == "pr_created"
      assert_closed_and_released(calls)
      assert called?(calls, "git_pr")
    end

    test "change_committed without PR" do
      assert {{:ok, result}, calls} = run_fixture(:change_committed)
      assert result.context["status"] == "change_committed"
      assert_closed_and_released(calls)
      assert called?(calls, "git_commit")
      refute called?(calls, "git_pr")
      assert result.context["commit_hash"] == "commitabc123"

      assert {"coding_workspace_committed_change", materialize_args} =
               Enum.find(calls, fn {name, _args} ->
                 name == "coding_workspace_committed_change"
               end)

      assert materialize_args["commit"] == "commitabc123"
      assert_json_clean_context(result.context)
      assert_opaque_handles(result.context)
    end

    test "clean self-commit adopts HEAD and does not call git_commit" do
      assert {{:ok, result}, calls} =
               run_fixture(:self_commit_adopt, %{"submit_review" => "false", "open_pr" => "false"})

      assert result.context["status"] == "change_committed"
      assert result.context["commit_hash"] == "selfcommit9999"
      refute called?(calls, "git_commit")
      assert_closed_and_released(calls)
    end

    test "fake-run contexts are JSON-clean with only opaque workspace/worker strings" do
      assert {{:ok, result}, _calls} = run_fixture(:change_committed)
      assert_json_clean_context(result.context)
      assert_opaque_handles(result.context)

      refute Enum.any?(result.context, fn {_k, v} ->
               is_pid(v) or is_function(v) or is_reference(v)
             end)
    end
  end

  describe "hard-failure routing and cleanup" do
    test "acquire failure is pipeline_error without workspace release" do
      assert {{:ok, result}, calls} = run_fixture(:acquire_failed)
      assert result.context["status"] == "pipeline_error"
      refute called?(calls, "coding_workspace_release")
      refute called?(calls, "acp_close_session")
    end

    test "worker open failure releases workspace only" do
      assert {{:ok, result}, calls} = run_fixture(:worker_open_failed)
      assert result.context["status"] == "pipeline_error"
      assert_released(calls)
      refute called?(calls, "acp_close_session")
      refute called?(calls, "acp_send_message")
    end

    test "implement hard failure sets pipeline_error and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:implement_hard_fail)
      assert result.context["status"] == "pipeline_error"
      assert_closed_and_released(calls)
    end

    test "structured-output extraction hard failure sets pipeline_error and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:extract_hard_fail)
      assert result.context["status"] == "pipeline_error"
      assert_closed_and_released(calls)
    end

    test "workspace inspect hard failure sets pipeline_error and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:inspect_hard_fail)
      assert result.context["status"] == "pipeline_error"
      assert_closed_and_released(calls)
    end

    test "validation hard failure sets validation_failed and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:validation_hard_fail)
      assert result.context["status"] == "validation_failed"
      assert_closed_and_released(calls)
      refute called?(calls, "git_commit")
    end

    test "commit hard failure sets pipeline_error and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:commit_hard_fail)
      assert result.context["status"] == "pipeline_error"
      assert_closed_and_released(calls)
    end

    test "committed review-material failure sets review_failed and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:committed_change_failed)
      assert result.context["status"] == "review_failed"
      assert_closed_and_released(calls)
      refute called?(calls, "council_review_change")
    end

    test "close failure still releases workspace" do
      assert {{:ok, result}, calls} = run_fixture(:close_failed)
      assert result.context["status"] == "change_committed"
      assert called?(calls, "acp_close_session")
      assert_released(calls)
    end
  end
end
