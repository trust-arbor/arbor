defmodule Arbor.Agent.TrustPresetApplyTest do
  @moduledoc """
  Security-regression guard for commit 7721f506.

  A data-first `.md` template that declares a `trust_preset` must get that
  restrictive trust profile APPLIED to the agent at create time. Before the fix,
  `Lifecycle.apply_template_trust_preset/2` only fired for the legacy module
  `trust_preset/0` callback — so data-first templates silently fell back to the
  default (`:cautious` → baseline `:ask`) profile with none of the declared rules.
  The read-only-by-default agent roster would have shipped WIDE OPEN.

  Test 1 is the guard: create an agent from a template whose frontmatter declares
  `baseline: block` + read-only rules, read its trust profile, and assert the
  restrictive baseline + rules landed. Comment out the
  `apply_template_trust_preset(agent_id, opts, store)` call in
  `Lifecycle.ensure_trust_profile/2`
  and this test fails — the baseline reverts to the default `:ask`.

  Test 2 proves the preset path only fires when a preset is declared: a template
  with no `trust_preset` keeps the default `:ask` baseline and is NOT forced to
  `:block`.

  ## Test-env setup notes

  `arbor_agent`'s app supervisor does not bring up Security or Trust on test boot
  (`config :arbor_security/:arbor_trust, start_children: false`). This test starts
  the exact chain `Lifecycle.create/2` exercises: the Security identity ceremony +
  signing-key store (mirroring `IdentityAliasesTest`), the agent profile store
  (mirroring `ReconcilerTest` / `ManagerTest`), and Trust `Store` + `Manager`
  (`ensure_trust_profile` reads via `Arbor.Trust.get_trust_profile`, and
  `apply_template_trust_preset` writes via `Arbor.Trust.Store.update_profile`).
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arbor.Agent.{BranchSupervisor, Lifecycle}
  alias Arbor.Contracts.TenantContext
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Trust.Store, as: TrustStore

  @profiles_store :arbor_agent_profiles

  setup_all do
    # This test creates identities and grants capabilities with unsigned test
    # crypto, so it needs signing / strict-identity / verification OFF. Set these
    # explicitly rather than trusting the global default — a combined umbrella run
    # can have them in force. async: false, so a per-suite set holds; restore on
    # exit.
    prev_security =
      for key <- [:capability_signing_required, :strict_identity_mode, :identity_verification] do
        {key, Application.get_env(:arbor_security, key)}
      end

    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :identity_verification, false)

    on_exit(fn ->
      for {key, value} <- prev_security do
        if is_nil(value),
          do: Application.delete_env(:arbor_security, key),
          else: Application.put_env(:arbor_security, key, value)
      end
    end)

    trust_supervisor =
      start_supervised!(%{
        id: :trust_preset_apply_supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               {TrustStore, []},
               {Arbor.Trust.Manager, [circuit_breaker: false, decay: false, event_store: false]}
             ],
             [strategy: :one_for_one]
           ]},
        type: :supervisor
      })

    {:ok, trust_supervisor: trust_supervisor}
  end

  setup do
    # --- Security: the identity ceremony + signing-key persistence create/2 runs.
    # BufferedStores back the identity / signing-key / capability stores; the
    # GenServers below do the work. Added under the already-running (empty)
    # Arbor.Security.Supervisor, tolerating already-started for combined runs.
    security_backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      start_security_child(
        Supervisor.child_spec(
          {BufferedStore,
           name: name, backend: security_backend, write_mode: :sync, collection: collection},
          id: name
        )
      )
    end

    signing_authority_owner_token = make_ref()

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.SigningAuthorityStateOwner,
           broker_token: signing_authority_owner_token},
          {Arbor.Security.SigningAuthorityBroker,
           state_owner_token: signing_authority_owner_token},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      start_security_child(child)
    end

    # --- Agent profile store: create/2 persists the Profile here (persist_profile).
    if Process.whereis(@profiles_store) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles_store, backend: nil, write_mode: :sync},
          id: @profiles_store
        )
      )
    end

    :ok
  end

  describe "trust_preset applied at create time (security regression, commit 7721f506)" do
    test "a data-first template's declarative trust_preset lands on the agent's trust profile" do
      assert {:ok, profile} = Lifecycle.create("Test Agent Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, tp} = TrustStore.get_profile(agent_id)

      # THE GUARD. Without apply_template_trust_preset firing for data-first
      # templates, baseline would be the default :ask and none of these rules
      # would be present.
      assert tp.baseline == :block
      # Bare-prefix rules (trust rules match by prefix, not glob — see
      # Arbor.Contracts.Security.TrustRule; templates are bare as of 59fa2cef and the
      # normalize path canonicalizes any glob form to bare regardless).
      assert tp.rules["arbor://fs/read"] == :allow
      assert tp.rules["arbor://fs/list"] == :allow
      assert tp.rules["arbor://orchestrator/execute"] == :allow
    end

    test "template orchestrator grant covers mandatory per-node middleware checks" do
      assert {:ok, profile} = Lifecycle.create("Middleware Gate Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute", :execute)

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute/exec", :execute)
    end

    test "security regression: coding template authorizes every canonical graph action" do
      assert {:ok, profile} =
               Lifecycle.create("Coding Graph Gate Probe", template: "coding_agent")

      agent_id = profile.agent_id
      cleanup(agent_id)

      # Outer reviewed-commit gate is orchestration control (:auto). Exact git
      # commit remains human-gated (:ask) — capability is present either way.
      auto_uris = [
        "arbor://action/coding/workspace/acquire",
        "arbor://action/coding/workspace/inspect",
        "arbor://action/coding/workspace/committed_change",
        "arbor://action/coding/workspace/release",
        "arbor://action/coding/review_tree/read",
        "arbor://action/coding/review_tree/search",
        "arbor://action/coding/reviewed_commit",
        "arbor://acp/tool/execute",
        "arbor://action/mix/compile",
        "arbor://action/git/pr",
        "arbor://action/council/review"
      ]

      for resource_uri <- auto_uris do
        assert {:ok, :authorized} =
                 Arbor.Trust.authorize(agent_id, resource_uri, :execute),
               "expected coding agent to authorize #{resource_uri}"
      end

      # git/commit is ask — capability held, but ApprovalGuard may escalate.
      git_commit = "arbor://action/git/commit"

      case Arbor.Trust.authorize(agent_id, git_commit, :execute) do
        {:ok, :authorized} ->
          :ok

        {:ok, :pending_approval, request_id} when is_binary(request_id) ->
          :ok

        other ->
          flunk("expected coding agent to hold git/commit authority, got #{inspect(other)}")
      end

      assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      uris = Enum.map(caps, & &1.resource_uri)
      assert Enum.any?(uris, &String.starts_with?(&1, "arbor://action/coding/reviewed_commit"))
      assert Enum.any?(uris, &String.starts_with?(&1, "arbor://action/git"))
    end

    test "template repo file grants mint concrete FileGuard scopes" do
      assert {:ok, profile} = Lifecycle.create("Repo File Tool Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id)

      repo_root =
        repo_root()
        |> String.trim_leading("/")

      assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      uris = Enum.map(caps, & &1.resource_uri)

      assert "arbor://fs/read" in uris
      assert "arbor://fs/list" in uris
      assert "arbor://fs/read/#{repo_root}/**" in uris
      assert "arbor://fs/list/#{repo_root}/**" in uris
      refute "arbor://fs/read/**" in uris
      refute "arbor://fs/list/**" in uris
    end

    test "security regression: read-only specialized templates with tenant_context do not receive workspace write grants" do
      for template <- ["test_agent", "security_auditor"] do
        workspace_root = tmp_workspace(template)
        File.mkdir_p!(workspace_root)
        on_exit(fn -> File.rm_rf(workspace_root) end)

        tenant_context =
          TenantContext.new("human_#{template}", workspace_root: workspace_root)

        assert {:ok, profile} =
                 Lifecycle.create("Tenant #{template} Probe",
                   template: template,
                   tenant_context: tenant_context
                 )

        agent_id = profile.agent_id
        cleanup(agent_id)

        workspace_uri_root = String.trim_leading(workspace_root, "/")

        assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
        uris = Enum.map(caps, & &1.resource_uri)

        assert "arbor://fs/read/#{workspace_uri_root}/**" in uris
        assert "arbor://fs/list/#{workspace_uri_root}/**" in uris
        refute Enum.any?(uris, &String.starts_with?(&1, "arbor://fs/write/"))

        assert {:error, _} =
                 Arbor.Security.authorize(agent_id, "arbor://fs/write", :execute,
                   file_path: Path.join(workspace_root, "should_not_write.txt")
                 )
      end
    end

    test "pipeline architect runtime restrictions are load-bearing through Session config" do
      assert {:ok, profile} =
               Lifecycle.create("Pipeline Architect Runtime Probe",
                 template: "pipeline_architect",
                 sandbox_level: :none
               )

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert profile.sandbox_level == :strict

      assert profile.initial_capabilities
             |> Enum.map(&(&1[:resource] || &1["resource"]))
             |> Enum.sort() ==
               Enum.sort([
                 "arbor://orchestrator/execute",
                 "arbor://fs/read/repo",
                 "arbor://fs/list/repo"
               ])

      original_cwd = File.cwd!()
      umbrella_root = umbrella_root_from(__DIR__)
      on_exit(fn -> File.cd!(original_cwd) end)
      File.cd!(Path.join(umbrella_root, "apps"))

      assert {:ok, ^agent_id} = Lifecycle.ensure_identity(agent_id)
      File.cd!(original_cwd)

      assert {:ok, _supervisor} =
               Lifecycle.start(agent_id,
                 runtime: :acp,
                 provider: :ollama,
                 model: "caller-override-must-not-stick",
                 context_management: :none,
                 tools: ["file_write", "shell_execute", "pipeline_run"],
                 sandbox_level: :none,
                 start_heartbeat: false,
                 recover_session: false
               )

      %{executor: executor, session: session} = BranchSupervisor.child_pids(agent_id)
      assert is_pid(executor)
      assert is_pid(session)

      session_state = Arbor.Orchestrator.Session.get_state(session)
      assert session_state.config["llm_runtime"] == :arbor
      assert session_state.config["llm_provider"] == "openai_oauth"
      assert session_state.config["llm_model"] == "gpt-5.5"

      assert session_state.config["tools"] ==
               ~w(file_read file_list file_search file_exists)

      refute Enum.any?(session_state.config["tools"], fn tool ->
               tool in ~w(file_write file_edit shell_execute agent_spawn_worker pipeline_run)
             end)

      assert :sys.get_state(executor).sandbox_level == :strict

      assert :ok = Lifecycle.stop(agent_id)

      assert {:ok, _supervisor} =
               Lifecycle.start(agent_id, start_heartbeat: false, recover_session: false)

      %{session: restored_session} = BranchSupervisor.child_pids(agent_id)
      restored_state = Arbor.Orchestrator.Session.get_state(restored_session)
      assert restored_state.config["llm_provider"] == "openai_oauth"
      assert restored_state.config["llm_model"] == "gpt-5.5"
    end

    test "pipeline architect capabilities and trust rules deny execution authority" do
      workspace_root = tmp_workspace("pipeline_architect_exact")
      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      assert {:ok, profile} =
               Lifecycle.create("Pipeline Architect Authority Probe",
                 template: "pipeline_architect",
                 tenant_context:
                   TenantContext.new("human_pipeline_architect", workspace_root: workspace_root),
                 capabilities: [
                   %{resource: "arbor://fs/write/**"},
                   %{resource: "arbor://shell/**"},
                   %{resource: "arbor://action/pipeline/run"}
                 ],
                 trust_preset: %{
                   baseline: :ask,
                   rules: %{"arbor://shell" => :auto}
                 }
               )

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert profile.initial_capabilities
             |> Enum.map(&(&1[:resource] || &1["resource"]))
             |> Enum.sort() ==
               Enum.sort([
                 "arbor://orchestrator/execute",
                 "arbor://fs/read/repo",
                 "arbor://fs/list/repo"
               ])

      assert {:ok, trust_profile} = TrustStore.get_profile(agent_id)
      assert trust_profile.baseline == :block
      assert trust_profile.rules["arbor://shell"] == :block

      for uri <- [
            "arbor://fs/write",
            "arbor://shell/exec",
            "arbor://acp/tool",
            "arbor://agent/dispatch",
            "arbor://agent/task/steer/task_1",
            "arbor://agent/spawn_worker",
            "arbor://trust/write",
            "arbor://governance/change",
            "arbor://action/coding/produce_reviewable_change",
            "arbor://action/pipeline/run",
            "arbor://pipeline/run",
            "arbor://orchestrator/map/dispatch",
            "arbor://orchestrator/execute/graph_mutation",
            "arbor://code/compile",
            "arbor://sandbox/create"
          ] do
        assert Arbor.Trust.effective_mode(agent_id, uri, []) == :block,
               "expected #{uri} to resolve to :block"

        result = Arbor.Trust.authorize(agent_id, uri, :execute)

        assert match?({:error, _reason}, result),
               "expected #{uri} authorization to fail, got: #{inspect(result)}"
      end

      assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      cap_uris = Enum.map(caps, & &1.resource_uri)
      repo_uri_root = repo_root() |> String.trim_leading("/")

      assert MapSet.new(cap_uris) ==
               MapSet.new([
                 "arbor://orchestrator/execute",
                 "arbor://orchestrator/execute/exec",
                 "arbor://orchestrator/execute/compute",
                 "arbor://orchestrator/execute/transform",
                 "arbor://orchestrator/execute/unknown",
                 "arbor://fs/read",
                 "arbor://fs/list",
                 "arbor://fs/read/#{repo_uri_root}/**",
                 "arbor://fs/list/#{repo_uri_root}/**"
               ])

      for uri <- [
            "arbor://orchestrator/execute",
            "arbor://orchestrator/execute/exec",
            "arbor://orchestrator/execute/compute",
            "arbor://orchestrator/execute/transform",
            "arbor://orchestrator/execute/unknown"
          ] do
        assert {:ok, :authorized} = Arbor.Security.authorize(agent_id, uri, :execute)
      end

      assert {:error, _reason} =
               Arbor.Security.authorize(
                 agent_id,
                 "arbor://orchestrator/execute/graph_mutation",
                 :execute
               )

      refute Enum.any?(cap_uris, fn uri ->
               String.starts_with?(uri, [
                 "arbor://fs/write",
                 "arbor://shell",
                 "arbor://acp",
                 "arbor://agent/dispatch",
                 "arbor://agent/spawn",
                 "arbor://trust/write",
                 "arbor://action/pipeline",
                 "arbor://pipeline/run"
               ])
             end)
    end

    test "security regression: malformed exact policy stops an already-running architect and revokes authority" do
      assert {:ok, profile} =
               Lifecycle.create("Corrupt Policy Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, _supervisor} =
               Lifecycle.start(agent_id, start_heartbeat: false, recover_session: false)

      corrupted =
        put_in(profile.metadata["exact_template_policy"]["digest"], String.duplicate("0", 64))

      assert :ok = Arbor.Agent.ProfileStore.store_profile(corrupted)

      assert {:error, _reason} = Lifecycle.start(agent_id, start_heartbeat: false)
      assert_eventually(fn -> is_nil(BranchSupervisor.whereis(agent_id)) end)
      assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
      assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
    end

    test "legacy Pipeline Architect profiles migrate to an exact snapshot before activation" do
      assert {:ok, profile} =
               Lifecycle.create("Legacy Architect Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id)

      legacy = %{profile | metadata: Map.delete(profile.metadata, "exact_template_policy")}
      assert :ok = Arbor.Agent.ProfileStore.store_profile(legacy)

      assert {:ok, ^agent_id} = Lifecycle.ensure_identity(agent_id)
      assert {:ok, migrated} = Lifecycle.restore(agent_id)
      assert %{} = migrated.metadata["exact_template_policy"]
    end

    test "security regression: a missing exact template fails closed and removes authority" do
      assert {:ok, profile} =
               Lifecycle.create("Missing Template Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert :ok =
               Arbor.Agent.ProfileStore.store_profile(%{
                 profile
                 | template: "missing_pipeline_architect"
               })

      assert {:error, _reason} = Lifecycle.ensure_identity(agent_id)
      assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
      assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
    end

    test "security regression: a changed exact template fails closed and removes authority" do
      assert {:ok, profile} =
               Lifecycle.create("Changed Template Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id)

      override_dir = tmp_workspace("changed_pipeline_template")
      File.mkdir_p!(override_dir)

      shipped_path =
        Path.join(Arbor.Agent.TemplateStore.shipped_templates_dir(), "pipeline_architect.md")

      changed_template =
        shipped_path
        |> File.read!()
        |> String.replace("model: \"gpt-5.5\"", "model: \"changed-template-model\"")

      File.write!(Path.join(override_dir, "pipeline_architect.md"), changed_template)
      Arbor.Agent.TemplateStore.set_templates_dir(override_dir)

      on_exit(fn ->
        Arbor.Agent.TemplateStore.clear_templates_dir_override()
        File.rm_rf(override_dir)
      end)

      assert {:error, _reason} = Lifecycle.ensure_identity(agent_id)
      assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
      assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
    end

    test "security regression: exact reconciliation revokes capabilities widened after creation" do
      assert {:ok, profile} =
               Lifecycle.create("Widened Capability Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, _capability} =
               Arbor.Security.grant(principal: agent_id, resource: "arbor://shell/exec")

      assert {:ok, ^agent_id} = Lifecycle.ensure_identity(agent_id)
      assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      refute "arbor://shell/exec" in Enum.map(caps, & &1.resource_uri)
    end

    test "security regression: creation fails when a declared trust preset cannot be stored",
         %{trust_supervisor: trust_supervisor} do
      before_ids = Lifecycle.list_agents() |> Enum.map(& &1.agent_id) |> MapSet.new()

      stop_trust_child(trust_supervisor, Arbor.Trust.Manager)
      stop_trust_child(trust_supervisor, TrustStore)

      result =
        try do
          Lifecycle.create("Unstored Restrictive Template Probe",
            template: "pipeline_architect"
          )
        after
          restart_trust_child(trust_supervisor, TrustStore)
          restart_trust_child(trust_supervisor, Arbor.Trust.Manager)
        end

      assert {:error, {:trust_profile_failed, _reason}} = result

      after_ids = Lifecycle.list_agents() |> Enum.map(& &1.agent_id) |> MapSet.new()
      assert after_ids == before_ids
    end

    test "a template WITHOUT a trust_preset is not forced to :block by this path" do
      assert {:ok, profile} =
               Lifecycle.create("Plain Agent Probe", template: "conversationalist")

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert {:ok, tp} = TrustStore.get_profile(agent_id)

      # Keeps the default (:cautious) profile — baseline :ask, NOT forced to
      # :block. Proves the preset path only fires when a preset is declared.
      assert tp.baseline == :ask
      refute tp.baseline == :block
    end

    test "non-exact template creation does not require an umbrella cwd" do
      original_cwd = File.cwd!()
      isolated_cwd = tmp_workspace("non_exact_cwd")
      File.mkdir_p!(isolated_cwd)

      on_exit(fn ->
        File.cd!(original_cwd)
        File.rm_rf(isolated_cwd)
      end)

      File.cd!(isolated_cwd)

      assert {:ok, profile} =
               Lifecycle.create("Non-exact CWD Probe", template: "conversationalist")

      cleanup(profile.agent_id)
    end
  end

  describe "concurrent lifecycle start security regression" do
    test "losing idempotent start permanently closes only its issued bootstrap" do
      assert {:ok, profile} =
               Lifecycle.create("Concurrent Bootstrap Probe", template: "test_agent")

      agent_id = profile.agent_id
      cleanup(agent_id)

      assert principal_bootstraps(agent_id) == []

      supervisor = Process.whereis(Arbor.Agent.Supervisor)
      assert is_pid(supervisor)
      :ok = :sys.suspend(supervisor)

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Lifecycle.start(agent_id, start_heartbeat: false, recover_session: false)
          end)
        end

      try do
        assert_eventually(fn -> length(principal_bootstraps(agent_id)) == 2 end)
      after
        :ok = :sys.resume(supervisor)
      end

      assert [{:ok, winner}, {:ok, winner}] = Task.await_many(tasks, 10_000)

      assert_eventually(fn ->
        case principal_bootstraps(agent_id) do
          [%{purpose: :session, status: status}] when status in [:unclaimed, :claimed] -> true
          _ -> false
        end
      end)
    end
  end

  # --- helpers ---

  defp assert_eventually(assertion, attempts \\ 50)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("expected condition to become true")

  defp principal_bootstraps(agent_id) do
    SigningAuthorityBroker.debug_state().bootstrap_entries
    |> Enum.filter(&(&1.principal_id == agent_id))
  end

  defp start_security_child(child) do
    case Supervisor.start_child(Arbor.Security.Supervisor, child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, _} -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp stop_trust_child(supervisor, child_id) do
    {^child_id, pid, :worker, _modules} =
      supervisor
      |> Supervisor.which_children()
      |> List.keyfind(child_id, 0)

    monitor = Process.monitor(pid)
    assert :ok = Supervisor.terminate_child(supervisor, child_id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 1_000
  end

  defp restart_trust_child(supervisor, child_id) do
    assert {:ok, pid} = Supervisor.restart_child(supervisor, child_id)
    assert Process.whereis(child_id) == pid
  end

  defp repo_root do
    cwd = File.cwd!() |> Path.expand()

    root =
      [cwd, Path.expand("../..", cwd), Path.expand("..", cwd)]
      |> Enum.find(fn path ->
        File.exists?(Path.join(path, "mix.exs")) and File.dir?(Path.join(path, "apps"))
      end)

    (root || cwd)
    |> String.trim_trailing("/")
  end

  defp umbrella_root_from(path) do
    expanded = Path.expand(path)

    cond do
      File.exists?(Path.join(expanded, "mix.exs")) and File.dir?(Path.join(expanded, "apps")) ->
        expanded

      Path.dirname(expanded) == expanded ->
        raise "could not locate umbrella root from #{path}"

      true ->
        umbrella_root_from(Path.dirname(expanded))
    end
  end

  defp tmp_workspace(template) do
    Path.join(
      System.tmp_dir!(),
      "arbor_#{template}_workspace_#{System.unique_integer([:positive])}"
    )
  end

  defp cleanup(agent_id) do
    on_exit(fn ->
      try do
        Lifecycle.destroy(agent_id)
      catch
        _, _ -> :ok
      end
    end)
  end
end
