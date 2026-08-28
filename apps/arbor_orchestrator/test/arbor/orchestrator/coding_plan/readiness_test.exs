defmodule Arbor.Orchestrator.CodingPlan.ReadinessTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Contracts.LLM.ProviderObservation

  alias Arbor.Orchestrator.CodingPlan.{
    ActionCatalog,
    Readiness,
    ReadinessLiveCore,
    WorkspaceScope
  }

  alias Arbor.Orchestrator.CodingPlanTestActionCatalog

  @moduletag :fast

  @observed_at "2026-07-22T12:00:00.000Z"

  defmodule TestObservers do
    @moduledoc false

    def security_available?, do: invoke(:security_available?, [])
    def signing_key_status(agent_id), do: invoke(:signing_key_status, [agent_id])

    def acp_provider_readiness(provider, model),
      do: invoke(:acp_provider_readiness, [provider, model])

    def coding_toolchain_identity, do: invoke(:coding_toolchain_identity, [])
    def validation_capacity_observer, do: invoke(:validation_capacity_observer, [])

    def coding_dependency_baseline_admission(repo_path, base_ref),
      do: invoke(:coding_dependency_baseline_admission, [repo_path, base_ref])

    def coding_validation_runtime_admission,
      do: invoke(:coding_validation_runtime_admission, [])

    def review_panel(plan), do: invoke(:review_panel, [plan])

    defp invoke(key, args) do
      case Process.get({:readiness_observer, key}) do
        function when is_function(function, length(args)) -> apply(function, args)
        value -> value
      end
    end
  end

  defmodule DependencyBaselineDigestStub do
    @moduledoc false

    def linux_dependency_baseline_mix_lock_digest do
      case Process.get(:dependency_baseline_digest) do
        digest when is_binary(digest) -> {:ok, digest}
        _other -> {:error, :linux_dependency_baseline_unavailable}
      end
    end
  end

  setup_all do
    template_path =
      Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot")

    {:ok, action_catalog} =
      ActionCatalog.snapshot(modules: CodingPlanTestActionCatalog.modules())

    %{template_source: File.read!(template_path), action_catalog: action_catalog}
  end

  setup do
    original_observer_module =
      Application.get_env(:arbor_orchestrator, :coding_readiness_observer_module)

    Application.put_env(
      :arbor_orchestrator,
      :coding_readiness_observer_module,
      TestObservers
    )

    root = Path.join(System.tmp_dir!(), "readiness-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    worktrees = Path.join(root, "worktrees")
    File.mkdir_p!(repo)
    File.mkdir_p!(worktrees)
    {"", 0} = System.cmd("git", ["init", "--quiet", repo])

    on_exit(fn ->
      File.rm_rf!(root)

      case original_observer_module do
        nil ->
          Application.delete_env(:arbor_orchestrator, :coding_readiness_observer_module)

        module ->
          Application.put_env(:arbor_orchestrator, :coding_readiness_observer_module, module)
      end
    end)

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
    assert "dependency_baseline_unavailable" in codes
    assert "acp_health_unavailable" in codes
    assert "toolchain_identity_unavailable" in codes
    assert "validation_capacity_unavailable" in codes
    assert "review_panel_unavailable" in codes

    assert Enum.map(report["diagnostics"], & &1["gate_id"]) == [
             "plan_schema",
             "trusted_roots",
             "compiler",
             "provenance",
             "security_authority",
             "dependency_baseline",
             "acp_health",
             "toolchain_identity",
             "validation_capacity",
             "review_panel"
           ]

    assert diagnostic(report, "dependency_baseline")["decision"] == "unavailable"
    assert File.ls!(ctx.repo) == before
  end

  test "live prerequisites return honest degraded readiness without mutating the repo", ctx do
    before = File.ls!(ctx.repo)

    assert {:ok, report} = Readiness.check(plan(ctx.repo), live_opts(ctx))

    assert report["status"] == "degraded"
    assert report["expires_at"] == "2026-07-22T12:00:30.000Z"
    assert Enum.count(report["diagnostics"], &(&1["decision"] == "blocked")) == 0
    assert diagnostic(report, "dependency_baseline")["decision"] == "passed"
    assert diagnostic(report, "dependency_baseline")["code"] == "dependency_baseline_matched"
    assert diagnostic(report, "dependency_baseline")["evidence_ref"] == "podman"
    assert diagnostic(report, "acp_health")["decision"] == "degraded"
    assert diagnostic(report, "acp_health")["code"] == "acp_health_degraded"
    assert diagnostic(report, "validation_capacity")["decision"] == "unavailable"
    # No review_panel observer stubbed: the plane degrades as unobserved rather
    # than blocking or vanishing.
    assert diagnostic(report, "review_panel")["decision"] == "degraded"
    assert diagnostic(report, "review_panel")["code"] == "review_panel_unobserved"
    assert Enum.all?(report["diagnostics"], &json_clean?/1)
    refute inspect(report) =~ "mix_wrapper_path"
    assert File.ls!(ctx.repo) == before
  end

  test "live review panel reports available, degraded-with-remedy, and never blocks", ctx do
    passed = %{
      status: :passed,
      total: 10,
      preferred: 10,
      fallback: 0,
      unresolved: 0,
      distinct_providers: 3,
      seats: []
    }

    Process.put({:readiness_observer, :review_panel}, fn _plan -> {:ok, passed} end)
    assert {:ok, report} = Readiness.check(plan(ctx.repo), live_opts(ctx))
    assert diagnostic(report, "review_panel")["decision"] == "passed"
    assert diagnostic(report, "review_panel")["code"] == "review_panel_available"
    assert diagnostic(report, "review_panel")["message"] =~ "All 10 review seats"

    degraded = %{
      passed
      | status: :degraded,
        preferred: 2,
        fallback: 0,
        unresolved: 8,
        distinct_providers: 2,
        seats: [%{id: "seat_a", preferred: {"ollama", "m"}, resolved: nil, outcome: :unresolved}]
    }

    Process.put({:readiness_observer, :review_panel}, fn _plan -> {:ok, degraded} end)
    assert {:ok, report} = Readiness.check(plan(ctx.repo), live_opts(ctx))
    assert diagnostic(report, "review_panel")["decision"] == "degraded"
    assert diagnostic(report, "review_panel")["code"] == "review_panel_degraded"
    assert diagnostic(report, "review_panel")["message"] =~ "8 will abstain"
    assert diagnostic(report, "review_panel")["remediation"] =~ "llm_fallback_providers"
    assert Enum.count(report["diagnostics"], &(&1["decision"] == "blocked")) == 0
  end

  test "live security failure is primary and short-circuits ACP, toolchain, and capacity", ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        security_available?: fn -> false end,
        coding_validation_runtime_admission: fn -> send(test_pid, :runtime_called) end,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          send(test_pid, :baseline_called)
        end,
        acp_provider_readiness: fn _provider, _model -> send(test_pid, :acp_called) end,
        coding_toolchain_identity: fn -> send(test_pid, :toolchain_called) end,
        validation_capacity_observer: fn -> send(test_pid, :capacity_called) end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "security_authority_unavailable"
    refute_received :runtime_called
    refute_received :baseline_called
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

  @tag :security_regression
  test "security regression: mismatched mix.lock at the exact base commit blocks before ACP or workspace work",
       ctx do
    test_pid = self()
    contents = "%{\"stale\" => \"lock\"}\n"
    base_commit = commit_mix_lock!(ctx.repo, contents)
    expected_digest = mix_lock_digest("%{\"baseline\" => \"pinned\"}\n")
    actual_digest = mix_lock_digest(contents)

    previous_digest_module =
      Application.get_env(:arbor_actions, :dependency_baseline_digest_module)

    Application.put_env(
      :arbor_actions,
      :dependency_baseline_digest_module,
      DependencyBaselineDigestStub
    )

    Process.put(:dependency_baseline_digest, expected_digest)

    on_exit(fn ->
      restore_actions_env(:dependency_baseline_digest_module, previous_digest_module)
    end)

    before = File.ls!(ctx.repo)
    {before_worktrees, 0} = System.cmd("git", ["worktree", "list"], cd: ctx.repo)

    opts =
      live_opts(ctx,
        coding_dependency_baseline_admission: fn repo, ref ->
          send(test_pid, {:baseline_called, repo, ref})
          Arbor.Actions.coding_dependency_baseline_admission(repo, ref)
        end,
        acp_provider_readiness: fn _provider, _model -> send(test_pid, :acp_called) end,
        coding_toolchain_identity: fn -> send(test_pid, :toolchain_called) end,
        validation_capacity_observer: fn -> send(test_pid, :capacity_called) end
      )

    assert {:ok, report} =
             Readiness.check(plan(ctx.repo, %{"base_ref" => base_commit}), opts)

    assert report["status"] == "blocked"
    assert blocked_code(report) == "dependency_baseline_mismatch"
    assert_received {:baseline_called, _repo, ^base_commit}
    refute_received :acp_called
    refute_received :toolchain_called
    refute_received :capacity_called
    refute inspect(report) =~ actual_digest
    refute inspect(report) =~ expected_digest
    refute inspect(report) =~ ctx.repo
    assert File.ls!(ctx.repo) == before
    {after_worktrees, 0} = System.cmd("git", ["worktree", "list"], cd: ctx.repo)
    assert after_worktrees == before_worktrees
  end

  test "live runtime observer raise, exit, throw, and malformed results fail closed", ctx do
    test_pid = self()

    for {label, observer} <- [
          {:raise, fn -> raise "runtime boom" end},
          {:exit, fn -> exit(:runtime_exit) end},
          {:throw, fn -> throw(:runtime_throw) end},
          {:malformed, fn -> {:ok, %{"driver" => "podman", "digest" => "secret"}} end}
        ] do
      opts =
        live_opts(ctx,
          coding_validation_runtime_admission: observer,
          coding_dependency_baseline_admission: fn _repo, _ref ->
            send(test_pid, {:mix_lock_called, label})
          end
        )

      assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
      assert report["status"] == "blocked"
      assert blocked_code(report) == "runtime_invalid"
      refute inspect(report) =~ "secret"
      refute_received {:mix_lock_called, ^label}
    end
  end

  test "live baseline observer raise, exit, throw, and malformed results fail closed", ctx do
    test_pid = self()

    for {label, observer} <- [
          {:raise, fn _repo, _ref -> raise "baseline boom" end},
          {:exit, fn _repo, _ref -> exit(:baseline_exit) end},
          {:throw, fn _repo, _ref -> throw(:baseline_throw) end},
          {:malformed, fn _repo, _ref -> {:ok, %{"matched" => true, "digest" => "secret"}} end}
        ] do
      opts =
        live_opts(ctx,
          coding_dependency_baseline_admission: observer,
          acp_provider_readiness: fn _provider, _model -> send(test_pid, {:acp_called, label}) end
        )

      assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
      assert report["status"] == "blocked"
      assert blocked_code(report) == "dependency_baseline_invalid"
      refute inspect(report) =~ "secret"
      refute_received {:acp_called, ^label}
    end
  end

  test "live unavailable baseline, unreadable mix.lock, and unresolvable base_ref block", ctx do
    test_pid = self()

    for {reason, code} <- [
          {:digest_mismatch, "dependency_baseline_mismatch"},
          {:baseline_unavailable, "dependency_baseline_unavailable"},
          {:mix_lock_unreadable_at_base_commit, "dependency_baseline_mix_lock_unreadable"},
          {:base_ref_unresolvable, "dependency_baseline_base_ref_unresolvable"}
        ] do
      opts =
        live_opts(ctx,
          coding_dependency_baseline_admission: fn _repo, _ref -> {:error, reason} end,
          acp_provider_readiness: fn _provider, _model ->
            send(test_pid, {:acp_called, reason})
          end
        )

      assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
      assert report["status"] == "blocked"
      assert blocked_code(report) == code
      refute_received {:acp_called, ^reason}
    end
  end

  test "pure baseline classifier admits only the exact matched envelope" do
    assert ReadinessLiveCore.dependency_baseline({:ok, %{"matched" => true}}) == {:ok, :passed}

    assert ReadinessLiveCore.dependency_baseline({:error, :digest_mismatch}) ==
             {:error, :mismatch}

    assert ReadinessLiveCore.dependency_baseline({:error, :baseline_unavailable}) ==
             {:error, :unavailable}

    assert ReadinessLiveCore.dependency_baseline({:error, :mix_lock_unreadable_at_base_commit}) ==
             {:error, :mix_lock_unreadable}

    assert ReadinessLiveCore.dependency_baseline({:error, :base_ref_unresolvable}) ==
             {:error, :base_ref_unresolvable}

    assert ReadinessLiveCore.dependency_baseline({:ok, %{"matched" => true, "digest" => "x"}}) ==
             {:error, :malformed}

    assert ReadinessLiveCore.dependency_baseline(:ok) == {:error, :malformed}
  end

  test "pure runtime classifier admits pinned+passed and distinguishes unconfigured from probe failure" do
    passed = runtime_envelope()
    assert ReadinessLiveCore.validation_runtime({:ok, passed}) == {:ok, :passed, "podman"}

    unconfigured = runtime_envelope(state: "unavailable", probe: "skipped")

    assert ReadinessLiveCore.validation_runtime({:ok, unconfigured}) ==
             {:error, :unconfigured, "podman", "linux"}

    probe_failed = runtime_envelope(probe: "failed")

    assert ReadinessLiveCore.validation_runtime({:ok, probe_failed}) ==
             {:error, :probe_failed, "podman"}

    probe_failed_detail =
      runtime_envelope(
        probe: "failed",
        extras: %{
          "probe_exit_code" => "2",
          "probe_output_tail" => "runtime/cgo: pthread_create failed"
        }
      )

    assert ReadinessLiveCore.validation_runtime({:ok, probe_failed_detail}) ==
             {:error, :probe_failed, "podman",
              %{
                "probe_exit_code" => "2",
                "probe_output_tail" => "runtime/cgo: pthread_create failed"
              }}

    untrusted_home = runtime_envelope(probe: "failed_untrusted_home")

    assert ReadinessLiveCore.validation_runtime({:ok, untrusted_home}) ==
             {:error, :probe_failed_untrusted_home, "podman"}

    starting = runtime_envelope(probe: "failed_starting")

    assert ReadinessLiveCore.validation_runtime({:ok, starting}) ==
             {:error, :probe_failed_starting, "podman"}

    assert ReadinessLiveCore.validation_runtime({:ok, Map.put(passed, "digest", "x")}) ==
             {:error, :malformed}

    assert ReadinessLiveCore.validation_runtime(:ok) == {:error, :malformed}
  end

  test "live unconfigured Linux runtime is runtime_unconfigured and does not run mix.lock",
       ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        coding_validation_runtime_admission: fn ->
          send(test_pid, :runtime_called)
          {:ok, runtime_envelope(state: "unavailable", probe: "skipped")}
        end,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          send(test_pid, :mix_lock_called)
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "runtime_unconfigured"
    diagnostic = diagnostic(report, "dependency_baseline")
    assert diagnostic["evidence_ref"] == "podman"
    assert diagnostic["remediation"] =~ "mix arbor.baseline.build"
    assert diagnostic["remediation"] =~ "mix arbor.baseline.activate"
    refute diagnostic["remediation"] =~ "Restore the reviewed Linux dependency baseline"
    assert_received :runtime_called
    refute_received :mix_lock_called
  end

  test "live unconfigured macOS runtime keeps Apple Container install wording", ctx do
    opts =
      live_opts(ctx,
        coding_validation_runtime_admission: fn ->
          {:ok,
           runtime_envelope(
             driver: "apple_container",
             state: "unavailable",
             probe: "skipped",
             host_os: "macos"
           )}
        end,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          flunk("mix.lock must not run when the runtime is unconfigured")
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert blocked_code(report) == "runtime_unconfigured"
    diagnostic = diagnostic(report, "dependency_baseline")
    assert diagnostic["evidence_ref"] == "apple_container"
    assert diagnostic["remediation"] =~ "ARBOR_APPLE_CONTAINER_CONFIG_PATH"
    assert diagnostic["remediation"] =~ "/usr/local/etc/arbor/apple-container.json"
    refute diagnostic["remediation"] =~ "mix arbor.baseline.build"
  end

  test "live probe failure is distinct from baseline unavailable and names the driver",
       ctx do
    test_pid = self()

    opts =
      live_opts(ctx,
        coding_validation_runtime_admission: fn ->
          {:ok, runtime_envelope(probe: "failed")}
        end,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          send(test_pid, :mix_lock_called)
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert blocked_code(report) == "runtime_probe_failed"
    diagnostic = diagnostic(report, "dependency_baseline")
    assert diagnostic["evidence_ref"] == "podman"
    assert diagnostic["remediation"] =~ "podman"
    refute diagnostic["remediation"] =~ "Restore podman"
    refute diagnostic["remediation"] =~ "sha256"
    refute diagnostic["remediation"] =~ "/home"
    refute diagnostic["remediation"] =~ "/usr/"
    refute diagnostic["remediation"] =~ "Restore the reviewed Linux dependency baseline"
    refute_received :mix_lock_called
  end

  test "live probe failure with exit code and tail names them without Restore podman",
       ctx do
    opts =
      live_opts(ctx,
        coding_validation_runtime_admission: fn ->
          {:ok,
           runtime_envelope(
             probe: "failed",
             extras: %{
               "probe_exit_code" => "2",
               "probe_output_tail" =>
                 "runtime/cgo: pthread_create failed: Operation not permitted"
             }
           )}
        end,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          flunk("mix.lock must not run when the runtime probe failed")
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert blocked_code(report) == "runtime_probe_failed"
    diagnostic = diagnostic(report, "dependency_baseline")
    assert diagnostic["remediation"] =~ "exited 2"
    assert diagnostic["remediation"] =~ "pthread_create"
    refute diagnostic["remediation"] =~ "Restore podman"
    refute diagnostic["remediation"] =~ "sha256"
    refute diagnostic["remediation"] =~ "/home"
  end

  test "live starting probe failure asks to retry without restore podman",
       ctx do
    opts =
      live_opts(ctx,
        coding_validation_runtime_admission: fn ->
          {:ok, runtime_envelope(probe: "failed_starting")}
        end,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          flunk("mix.lock must not run when the runtime is still starting")
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert blocked_code(report) == "runtime_probe_failed"
    diagnostic = diagnostic(report, "dependency_baseline")
    assert diagnostic["remediation"] =~ "still starting"
    assert diagnostic["remediation"] =~ "Retry"
    refute diagnostic["remediation"] =~ "Restore podman"
    refute diagnostic["remediation"] =~ "/"
  end

  test "live untrusted HOME probe failure names chmod go-w, not restore podman",
       ctx do
    opts =
      live_opts(ctx,
        coding_validation_runtime_admission: fn ->
          {:ok, runtime_envelope(probe: "failed_untrusted_home")}
        end,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          flunk("mix.lock must not run when the runtime probe failed")
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert blocked_code(report) == "runtime_probe_failed"
    diagnostic = diagnostic(report, "dependency_baseline")
    assert diagnostic["evidence_ref"] == "podman"
    assert diagnostic["remediation"] =~ "chmod go-w"
    assert diagnostic["remediation"] =~ "0755"
    refute diagnostic["remediation"] =~ "Restore podman"
    refute diagnostic["remediation"] =~ "/home"
  end

  test "live mix.lock unavailable keeps the existing authority remedy after a passing runtime",
       ctx do
    opts =
      live_opts(ctx,
        coding_dependency_baseline_admission: fn _repo, _ref ->
          {:error, :baseline_unavailable}
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert blocked_code(report) == "dependency_baseline_unavailable"
    diagnostic = diagnostic(report, "dependency_baseline")
    assert diagnostic["evidence_ref"] == "podman"

    assert diagnostic["remediation"] ==
             "Restore the reviewed Linux dependency baseline before dispatch."
  end

  test "live passed Apple runtime shows apple_container on the report", ctx do
    opts =
      live_opts(ctx,
        coding_validation_runtime_admission: fn ->
          {:ok, runtime_envelope(driver: "apple_container", host_os: "macos")}
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert diagnostic(report, "dependency_baseline")["code"] == "dependency_baseline_matched"
    assert diagnostic(report, "dependency_baseline")["evidence_ref"] == "apple_container"
    refute inspect(report) =~ "/usr/local/etc/arbor"
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

  test "live expired ACP evidence is blocked and never promoted to the default TTL", ctx do
    opts =
      live_opts(ctx,
        acp_provider_readiness: fn _provider, _model ->
          acp_envelope(
            observed_at: "2026-07-22T11:59:50Z",
            expires_at: "2026-07-22T12:00:00Z"
          )
        end,
        coding_toolchain_identity: fn -> flunk("toolchain must not be observed") end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "acp_evidence_expired"
    assert report["expires_at"] == "2026-07-22T12:00:30.000Z"
  end

  test "fixed readiness observations reject ACP evidence after the supplied endpoint", ctx do
    opts =
      live_opts(ctx,
        acp_provider_readiness: fn _provider, _model ->
          acp_envelope(
            observed_at: "2026-07-22T12:00:01Z",
            expires_at: "2026-07-22T12:00:30Z"
          )
        end
      )

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "acp_evidence_future"
  end

  @tag :security_regression
  test "security regression: synchronous ACP evidence is admitted through the observed collection endpoint",
       ctx do
    observed_through = ~U[2026-07-22 12:00:10Z]

    opts =
      live_opts(ctx,
        acp_provider_readiness: fn _provider, _model ->
          acp_envelope(
            observed_at: "2026-07-22T12:00:10Z",
            expires_at: "2026-07-22T12:00:40Z"
          )
        end
      )
      |> Keyword.put(:observation_clock, fn -> observed_through end)

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "degraded"
    assert report["observed_at"] == "2026-07-22T12:00:10Z"
    assert report["expires_at"] == "2026-07-22T12:00:40Z"
    assert diagnostic(report, "acp_health")["decision"] == "degraded"
    assert Enum.all?(report["diagnostics"], &(&1["observed_at"] == report["observed_at"]))
  end

  test "live ACP evidence beyond the observed collection endpoint is blocked", ctx do
    observed_through = ~U[2026-07-22 12:00:10Z]

    opts =
      live_opts(ctx,
        acp_provider_readiness: fn _provider, _model ->
          acp_envelope(
            observed_at: "2026-07-22T12:00:11Z",
            expires_at: "2026-07-22T12:00:40Z"
          )
        end,
        coding_toolchain_identity: fn -> flunk("toolchain must not be observed") end
      )
      |> Keyword.put(:observation_clock, fn -> observed_through end)

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "acp_evidence_future"
  end

  test "invalid live observation clocks fail closed with one diagnostic", ctx do
    opts =
      ctx
      |> live_opts()
      |> Keyword.put(:observation_clock, fn -> :not_a_datetime end)

    assert {:ok, report} = Readiness.check(plan(ctx.repo), opts)
    assert report["status"] == "blocked"
    assert blocked_code(report) == "observation_clock_invalid"

    assert Enum.count(
             report["diagnostics"],
             &(&1["code"] == "observation_clock_invalid")
           ) == 1
  end

  test "pure expiry rejects provider expiry at or before readiness time" do
    observed_at = ~U[2026-07-22 12:00:00Z]

    assert {:error, :expired} =
             ReadinessLiveCore.expiry(observed_at, "2026-07-22T11:59:59Z")

    assert {:error, :expired} =
             ReadinessLiveCore.expiry(observed_at, "2026-07-22T12:00:00Z")
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

  test "prepared readiness rejects a compilation that no longer matches the canonical plan",
       ctx do
    assert {:ok, canonical_plan, compilation} =
             Readiness.prepare(plan(ctx.repo), readiness_opts(ctx))

    mismatched = %{compilation | plan_map: Map.put(compilation.plan_map, "task", "redirected")}

    assert {:ok, report} =
             Readiness.check_prepared(
               canonical_plan,
               mismatched,
               readiness_opts(ctx) |> Keyword.put(:mode, :live)
             )

    assert report["status"] == "blocked"
    assert blocked_code(report) == "prepared_compilation_invalid"
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

    # The property under test is that caller-supplied roots are IGNORED, not the
    # particular status that results. In static mode an unconfigured root now
    # reports "unavailable"/degraded rather than "blocked", because static mode
    # runs without runtime config and cannot observe a root the runtime creates
    # at boot. What must stay true is that the override buys the caller nothing:
    # the trusted_roots gate still fires and the report never reaches "ready".
    refute report["status"] == "ready"
    assert Enum.any?(report["diagnostics"], &(&1["gate_id"] == "trusted_roots"))
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
    Process.put(
      {:readiness_observer, :security_available?},
      Keyword.get(overrides, :security_available?, true)
    )

    Process.put(
      {:readiness_observer, :signing_key_status},
      Keyword.get(overrides, :signing_key_status, fn _ -> {:ok, :available} end)
    )

    Process.put(
      {:readiness_observer, :acp_provider_readiness},
      Keyword.get(overrides, :acp_provider_readiness, fn provider, model ->
        acp_envelope(provider: provider, model: model)
      end)
    )

    Process.put(
      {:readiness_observer, :coding_toolchain_identity},
      Keyword.get(overrides, :coding_toolchain_identity, fn -> {:ok, toolchain_identity()} end)
    )

    Process.put(
      {:readiness_observer, :validation_capacity_observer},
      Keyword.get(overrides, :validation_capacity_observer, :unavailable)
    )

    Process.put(
      {:readiness_observer, :coding_dependency_baseline_admission},
      Keyword.get(overrides, :coding_dependency_baseline_admission, fn _repo, _ref ->
        {:ok, %{"matched" => true}}
      end)
    )

    Process.put(
      {:readiness_observer, :coding_validation_runtime_admission},
      Keyword.get(overrides, :coding_validation_runtime_admission, fn ->
        {:ok, runtime_envelope()}
      end)
    )

    readiness_opts(ctx)
    |> Keyword.merge(
      mode: :live,
      agent_id: "agent_readiness_test"
    )
    |> Keyword.merge(overrides)
    |> Keyword.drop([
      :security_available?,
      :signing_key_status,
      :acp_provider_readiness,
      :coding_toolchain_identity,
      :validation_capacity_observer,
      :coding_dependency_baseline_admission,
      :coding_validation_runtime_admission
    ])
  end

  defp runtime_envelope(opts \\ []) do
    extras = Keyword.get(opts, :extras, %{})

    %{
      "driver" => Keyword.get(opts, :driver, "podman"),
      "state" => Keyword.get(opts, :state, "pinned"),
      "probe" => Keyword.get(opts, :probe, "passed"),
      "host_os" => Keyword.get(opts, :host_os, "linux")
    }
    |> Map.merge(extras)
  end

  defp acp_envelope(opts) do
    failure_code = Keyword.get(opts, :failure_code)

    attrs =
      %{
        provider: Keyword.get(opts, :provider, "grok"),
        source: "acp_provider_readiness",
        runtime: "acp",
        observed_at: Keyword.get(opts, :observed_at, @observed_at),
        expires_at: Keyword.get(opts, :expires_at, "2026-07-22T12:00:30Z"),
        availability: Keyword.get(opts, :availability, "degraded"),
        auth_health: Keyword.get(opts, :auth_health, "unknown"),
        model_catalog_membership: "unknown",
        quota_state: "unknown",
        subscription_capacity_state: "unknown",
        requested_model_id: Keyword.get(opts, :model, "grok-4.6"),
        launch_bound_model_id: "grok-4.6"
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
          "version" => 1,
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

  defp commit_mix_lock!(repo, contents) do
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
    File.write!(Path.join(repo, "mix.lock"), contents)
    {_, 0} = System.cmd("git", ["-C", repo, "add", "mix.lock"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-m", "add mix.lock", "--quiet"])
    {commit, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
    String.trim(commit)
  end

  defp mix_lock_digest(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  end

  defp restore_actions_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_actions_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
