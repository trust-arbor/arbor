defmodule Arbor.Orchestrator.CodingPlan.ReadinessTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, Readiness, WorkspaceScope}

  @moduletag :fast

  @observed_at "2026-07-22T12:00:00.000Z"

  @action_modules [
    Arbor.Actions.Acp.StartSession,
    Arbor.Actions.Acp.SendMessage,
    Arbor.Actions.Acp.SessionStatus,
    Arbor.Actions.Acp.CloseSession,
    Arbor.Actions.Coding.Workspace.Acquire,
    Arbor.Actions.Coding.Workspace.Inspect,
    Arbor.Actions.Coding.Workspace.Release,
    Arbor.Actions.Coding.Workspace.CommittedChange,
    Arbor.Actions.Coding.Workspace.RecoverySummary,
    Arbor.Actions.Coding.SecurityRegression.Validate,
    Arbor.Actions.Coding.CrossApp.Validate,
    Arbor.Actions.Mix.Compile,
    Arbor.Actions.Mix.Test,
    Arbor.Actions.Coding.ReviewedCommit,
    Arbor.Actions.Git.Commit,
    Arbor.Actions.Git.PR,
    Arbor.Actions.Coding.ReviewTree.Read,
    Arbor.Actions.Coding.ReviewTree.Search,
    Arbor.Actions.Coding.SubmitReviewReport,
    Arbor.Actions.Council.ReviewChange,
    Arbor.Actions.Consensus.DecideReview
  ]

  setup_all do
    template_path =
      Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot")

    {:ok, action_catalog} = ActionCatalog.snapshot(modules: @action_modules)

    %{template_source: File.read!(template_path), action_catalog: action_catalog}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "readiness-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    worktrees = Path.join(root, "worktrees")
    File.mkdir_p!(repo)
    File.mkdir_p!(worktrees)
    {"", 0} = System.cmd("git", ["init", "--quiet", repo])

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, worktrees: worktrees}
  end

  test "valid static prerequisites return degraded with explicit unavailable facts", ctx do
    before = File.ls!(ctx.repo)

    assert {:ok, report} =
             Readiness.check(
               plan(ctx.repo),
               readiness_opts(ctx)
             )

    assert report["version"] == 1
    assert report["status"] == "degraded"
    assert report["observed_at"] == @observed_at
    assert Enum.all?(report["diagnostics"], &Map.has_key?(&1, "gate_id"))
    assert Enum.count(report["diagnostics"], &(&1["decision"] == "blocked")) == 0

    codes = Enum.map(report["diagnostics"], & &1["code"])
    assert "compilation_valid" in codes
    assert "security_authority_unavailable" in codes
    assert "acp_health_unavailable" in codes
    assert "toolchain_identity_unavailable" in codes
    assert "validation_capacity_unavailable" in codes
    assert File.ls!(ctx.repo) == before
  end

  test "prepare returns the canonical plan and the validated compilation used by readiness",
       ctx do
    nested = Path.join(ctx.repo, "apps/example")
    File.mkdir_p!(nested)

    assert {:ok, canonical_plan, compilation} =
             Readiness.prepare(plan(nested), readiness_opts(ctx))

    assert canonical_plan.repo_root == real_path!(ctx.repo)
    assert canonical_plan.workspace_policy["worktree_base_dir"] == real_path!(ctx.worktrees)
    assert compilation.plan_map == Plan.to_map(canonical_plan)

    assert {:ok, ^compilation} =
             Arbor.Orchestrator.CodingPlan.Compilation.validate(compilation, canonical_plan)
  end

  test "invalid plan is blocked with exactly one primary diagnostic", ctx do
    assert {:ok, report} =
             Readiness.check(
               %{"task" => "missing worker", "repo_root" => ctx.repo},
               readiness_opts(ctx)
             )

    assert report["status"] == "blocked"
    assert [diagnostic] = Enum.filter(report["diagnostics"], &(&1["decision"] == "blocked"))
    assert diagnostic["gate_id"] == "plan_schema"
    assert diagnostic["code"] == "plan_invalid"
    assert is_binary(diagnostic["remediation"])
  end

  test "non-executable profile is blocked before compilation", ctx do
    assert {:ok, report} =
             Readiness.check(
               plan(ctx.repo, %{"validation_profile" => "docs_only"}),
               readiness_opts(ctx)
             )

    assert report["status"] == "blocked"
    assert blocked_code(report) == "profile_not_executable"
  end

  test "catalog failure is a bounded action-catalog gate", ctx do
    bad_catalog = %{"actions" => [], "digest" => String.duplicate("0", 64)}

    assert {:ok, report} =
             Readiness.check(
               plan(ctx.repo),
               readiness_opts(ctx) |> Keyword.put(:action_catalog, bad_catalog)
             )

    assert report["status"] == "blocked"
    assert blocked_code(report) == "action_catalog_invalid"
  end

  test "invalid template is reported as a compiler gate without ACP or workspace work", ctx do
    before = File.ls!(ctx.repo)

    assert {:ok, report} =
             Readiness.check(
               plan(ctx.repo),
               readiness_opts(ctx) |> Keyword.put(:template_source, "not a dot graph")
             )

    assert report["status"] == "blocked"
    assert blocked_code(report) == "template_unavailable"
    assert File.ls!(ctx.repo) == before
  end

  test "unconfigured and unsafe roots are blocked", ctx do
    for {root_opts, expected_code} <- [
          {[repo_roots: [], worktree_roots: [ctx.worktrees]], "repo_roots_invalid"},
          {[repo_roots: [ctx.worktrees], worktree_roots: [ctx.worktrees]], "repo_outside_root"}
        ] do
      assert {:ok, report} =
               Readiness.check(
                 plan(ctx.repo),
                 readiness_opts(ctx) |> Keyword.merge(root_opts)
               )

      assert report["status"] == "blocked"
      assert blocked_code(report) == expected_code
    end
  end

  test "plain directories are blocked before compilation", ctx do
    plain = Path.join(Path.dirname(ctx.repo), "plain")
    File.mkdir_p!(plain)

    assert {:ok, report} = Readiness.check(plan(plain), readiness_opts(ctx))
    assert report["status"] == "blocked"
    assert blocked_code(report) == "invalid_git_repository"
  end

  test "nested repository paths and defaults normalize to the execution scope", ctx do
    nested = Path.join(ctx.repo, "apps/example")
    File.mkdir_p!(nested)

    assert {:ok, canonical} =
             WorkspaceScope.normalize(
               plan(nested),
               [Path.dirname(ctx.repo)],
               [ctx.worktrees]
             )

    assert canonical.repo_root == real_path!(ctx.repo)
    assert canonical.workspace_policy["worktree_base_dir"] == real_path!(ctx.worktrees)

    assert {:ok, root_report} = Readiness.check(plan(ctx.repo), readiness_opts(ctx))
    assert {:ok, nested_report} = Readiness.check(plan(nested), readiness_opts(ctx))
    assert nested_report["plan_digest"] == root_report["plan_digest"]
  end

  test "public facade ignores caller-supplied trusted evidence overrides", ctx do
    assert {:ok, report} =
             Arbor.Orchestrator.check_coding_readiness(
               plan(ctx.repo),
               readiness_opts(ctx)
             )

    assert report["status"] == "blocked"
    refute Enum.any?(report["diagnostics"], &(&1["code"] == "compilation_valid"))
  end

  defp readiness_opts(ctx) do
    [
      observed_at: @observed_at,
      repo_roots: [Path.dirname(ctx.repo)],
      worktree_roots: [ctx.worktrees],
      template_source: ctx.template_source,
      action_catalog: ctx.action_catalog
    ]
  end

  defp plan(repo, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "task" => "Check coding readiness",
          "repo_root" => repo,
          "worker" => %{"provider" => "grok"}
        },
        overrides
      )

    {:ok, plan} = Plan.new(attrs)
    plan
  end

  defp blocked_code(report) do
    report["diagnostics"]
    |> Enum.filter(&(&1["decision"] == "blocked"))
    |> case do
      [diagnostic] -> diagnostic["code"]
      diagnostics -> flunk("expected one blocking diagnostic, got #{inspect(diagnostics)}")
    end
  end

  defp real_path!(path) do
    {:ok, real_path} = Arbor.Common.SafePath.resolve_real(path)
    real_path
  end
end
