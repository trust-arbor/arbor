defmodule Arbor.Orchestrator.CodingPlan.ReadinessTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Contracts.LLM.ProviderObservation
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

  test "live prerequisites return honest degraded readiness without mutating the repo", ctx do
    before = File.ls!(ctx.repo)

    assert {:ok, report} = Readiness.check(plan(ctx.repo), live_opts(ctx))

    assert report["status"] == "degraded"
    assert report["expires_at"] == "2026-07-22T12:00:30.000Z"
    assert Enum.count(report["diagnostics"], &(&1["decision"] == "blocked")) == 0
    assert diagnostic(report, "acp_health")["decision"] == "degraded"
    assert diagnostic(report, "acp_health")["code"] == "acp_health_degraded"
    assert diagnostic(report, "validation_capacity")["decision"] == "unavailable"
    assert Enum.all?(report["diagnostics"], &json_clean?/1)
    refute inspect(report) =~ "mix_wrapper_path"
    assert File.ls!(ctx.repo) == before
  end

  test "live security failure is primary and short-circuits ACP, toolchain, and capacity", ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        security_available?: fn -> false end,
        acp_provider_readiness: fn _provider, _model -> send(test_pid, :acp_called) end,
        coding_toolchain_identity: fn -> send(test_pid, :toolchain_called) end,
        validation_capacity_observer: fn -> send(test_pid, :capacity_called) end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "security_authority_unavailable"
    refute_received :acp_called
    refute_received :toolchain_called
    refute_received :capacity_called
  end

  test "live invalid agent identity blocks before security observers", ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        agent_id: "human_not-an-agent",
        security_available?: fn -> send(test_pid, :security_called) end,
        signing_key_status: fn _agent_id -> send(test_pid, :signing_key_called) end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "agent_id_invalid"
    refute_received :security_called
    refute_received :signing_key_called
  end

  test "live signing-key failure blocks before ACP", ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        signing_key_status: fn _agent_id -> {:error, :no_signing_key} end,
        acp_provider_readiness: fn _provider, _model -> send(test_pid, :acp_called) end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "signing_key_unavailable"
    refute_received :acp_called
  end

  test "live ACP model mismatch is primary and short-circuits later gates", ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        acp_provider_readiness: fn _provider, _model ->
          send(test_pid, :acp_called)
          acp_envelope(expires_at: "2026-07-22T12:00:20Z", failure_code: "model_mismatch")
        end,
        coding_toolchain_identity: fn -> send(test_pid, :toolchain_called) end,
        validation_capacity_observer: fn -> send(test_pid, :capacity_called) end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "acp_model_mismatch"
    assert_received :acp_called
    refute_received :toolchain_called
    refute_received :capacity_called
  end

  test "live malformed ACP evidence is blocked without leaking provider details", ctx do
    secret = "provider-command-or-secret"

    opts =
      live_opts(ctx,
        acp_provider_readiness: fn _provider, _model ->
          %{"observation" => %{"failure_message" => secret}, "digest" => "not-a-digest"}
        end,
        coding_toolchain_identity: fn -> flunk("toolchain must not be observed") end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "acp_evidence_invalid"
    refute inspect(report) =~ secret
  end

  test "live malformed toolchain evidence is blocked and capacity is not observed", ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        coding_toolchain_identity: fn -> {:ok, %{"raw_output" => "do not return"}} end,
        validation_capacity_observer: fn -> send(test_pid, :capacity_called) end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "toolchain_identity_invalid"
    refute_received :capacity_called
    refute inspect(report) =~ "raw_output"
  end

  test "live expiry is bounded by an earlier valid ACP provider expiry", ctx do
    opts =
      live_opts(ctx,
        acp_provider_readiness: fn _provider, _model ->
          acp_envelope(expires_at: "2026-07-22T12:00:12Z")
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["expires_at"] == "2026-07-22T12:00:12Z"
  end

  test "unknown readiness modes fail closed with one diagnostic", ctx do
    assert {:ok, report} =
             Readiness.check(plan(ctx.repo), readiness_opts(ctx) |> Keyword.put(:mode, :probe))

    assert report["status"] == "blocked"
    assert blocked_code(report) == "mode_invalid"
    assert length(Enum.filter(report["diagnostics"], &(&1["decision"] == "blocked"))) == 1
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

  defp live_opts(ctx, overrides \\ []) do
    readiness_opts(ctx)
    |> Keyword.merge(
      mode: :live,
      agent_id: "agent_readiness_test",
      security_available?: fn -> true end,
      signing_key_status: fn _agent_id -> {:ok, :available} end,
      acp_provider_readiness: fn provider, model ->
        acp_envelope(provider: provider, model: model)
      end,
      coding_toolchain_identity: fn -> {:ok, toolchain_identity()} end
    )
    |> Keyword.merge(overrides)
  end

  defp acp_envelope(opts) do
    failure_code = Keyword.get(opts, :failure_code)

    attrs =
      %{
        provider: Keyword.get(opts, :provider, "grok"),
        source: "acp_provider_readiness",
        runtime: "acp",
        observed_at: @observed_at,
        expires_at: Keyword.get(opts, :expires_at, "2026-07-22T12:00:30Z"),
        availability: Keyword.get(opts, :availability, "degraded"),
        auth_health: Keyword.get(opts, :auth_health, "unknown"),
        model_catalog_membership: "unknown",
        quota_state: "unknown",
        subscription_capacity_state: "unknown",
        requested_model_id: Keyword.get(opts, :model, "grok-4.5"),
        launch_bound_model_id: "grok-4.5"
      }
      |> maybe_put(:failure_code, failure_code)
      |> maybe_put(
        :failure_message,
        Keyword.get(opts, :failure_message, failure_message(failure_code))
      )

    {:ok, observation} = ProviderObservation.normalize(attrs)
    {:ok, digest} = ProviderObservation.digest(observation)
    %{"observation" => observation, "digest" => digest}
  end

  defp toolchain_identity do
    identity = %{
      "schema_version" => 1,
      "platform" => "unix:test",
      "architecture" => "test",
      "otp_release" => "28",
      "elixir_version" => "1.19.5",
      "mix_wrapper_path" => "/reviewed/bin/mix",
      "runtime_roots" => %{
        "erlang_root" => "/runtime/erlang",
        "elixir_root" => "/runtime/elixir"
      }
    }

    Map.put(identity, "identity_digest", digest(identity))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp failure_message(nil), do: nil
  defp failure_message(_code), do: "bounded provider failure"

  defp digest(value) do
    :crypto.hash(:sha256, canonical_json(value))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> key end)
    |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ":", canonical_json(nested)] end)
    |> then(&["{", Enum.intersperse(&1, ","), "}"])
  end

  defp canonical_json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical_json/1), ","), "]"]

  defp canonical_json(value), do: Jason.encode!(value)

  defp diagnostic(report, gate_id) do
    Enum.find(report["diagnostics"], &(&1["gate_id"] == gate_id))
  end

  defp json_clean?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end)

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)
  defp json_clean?(value) when is_binary(value), do: String.valid?(value)
  defp json_clean?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json_clean?(_value), do: false

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
