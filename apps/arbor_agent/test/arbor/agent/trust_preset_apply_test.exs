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

  alias Arbor.Agent.{BranchSupervisor, Character, Lifecycle}
  alias Arbor.Agent.Test.{RuntimeAdmissionTopology, TrustTopology}
  alias Arbor.Contracts.Security.CapabilityUri
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

    trust_supervisor = TrustTopology.ensure_owned!()
    start_security_topology()

    # Lifecycle.create/2 and destroy/2 need an actor authority since ddf05e470.
    # Mint one actor for the module: every grant spends the run's audit journal
    # budget (see Arbor.Agent.LifecycleActorFixture). Each test reopens it.
    {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()
    on_exit(fn -> Arbor.Agent.close_lifecycle_actor_fixture(principal) end)

    {:ok, trust_supervisor: trust_supervisor, lifecycle_principal: principal}
  end

  setup %{lifecycle_principal: principal} do
    start_security_topology()

    # --- Agent profile store: create/2 persists the Profile here (persist_profile).
    if Process.whereis(@profiles_store) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles_store, backend: nil, write_mode: :sync},
          id: @profiles_store
        )
      )
    end

    # Own ready RA supervisor / Task.Supervisor / TaskStore per test so
    # Lifecycle.start exercises ordinary-start admission without ambient globals.
    topology = RuntimeAdmissionTopology.start_owned!()

    # The actor's authority must be owned by the test process that uses it.
    {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)

    Map.put(topology, :lifecycle_actor, actor)
  end

  defp start_security_topology do
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
  end

  describe "trust_preset applied at create time (security regression, commit 7721f506)" do
    test "a data-first template's declarative trust_preset lands on the agent's trust profile", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} = create_agent(actor, "Test Agent Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id, actor)

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

    test "template orchestrator grant covers mandatory per-node middleware checks", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} = create_agent(actor, "Middleware Gate Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute", :execute)

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute/exec", :execute)
    end

    test "an agent is authorized on its OWN memory at create time", %{lifecycle_actor: actor} do
      assert {:ok, profile} = create_agent(actor, "Self Memory Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      # `Arbor.Memory`'s facade gates each op on `arbor://memory/<op>/<agent_id>`,
      # a DIFFERENT and finer gate than the action-layer URIs a template declares
      # (`arbor://memory/recall`, `.../write`). Before the create-time grant an
      # agent cleared the action gate, ran Memory.Recall, and was then denied
      # INSIDE it with `{:unauthorized, :unauthorized}` — it could not search its
      # own memory while `memory_reflect` worked.
      for operation <- ~w[read write search] do
        assert {:ok, :authorized} =
                 Arbor.Security.authorize(
                   agent_id,
                   "arbor://memory/#{operation}/#{agent_id}",
                   :execute,
                   verify_identity: false
                 ),
               "agent cannot #{operation} its own memory"
      end
    end

    test "the self-memory grant does not reach another agent's memory", %{lifecycle_actor: actor} do
      assert {:ok, mine} = create_agent(actor, "Self Memory Owner", template: "test_agent")
      assert {:ok, theirs} = create_agent(actor, "Self Memory Stranger", template: "test_agent")
      cleanup(mine.agent_id, actor)
      cleanup(theirs.agent_id, actor)

      # The scoped URI is the boundary between reading MY memory and reading
      # ANOTHER agent's. Granting the baseline must not widen it into a blanket
      # `arbor://memory/read`.
      assert {:error, _} =
               Arbor.Security.authorize(
                 mine.agent_id,
                 "arbor://memory/read/#{theirs.agent_id}",
                 :execute,
                 verify_identity: false
               )
    end

    test "security regression: coding template authorizes every canonical graph action", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} =
               create_agent(actor, "Coding Graph Gate Probe", template: "coding_agent")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      # Outer reviewed-commit gate is orchestration control (:auto). Exact git
      # commit remains human-gated (:ask) — capability is present either way.
      auto_uris = [
        "arbor://action/coding/design_checkpoint/open",
        "arbor://action/coding/design_checkpoint/await",
        "arbor://action/coding/design_council_review",
        "arbor://action/coding/workspace/acquire",
        "arbor://action/coding/workspace/inspect",
        "arbor://action/coding/workspace/committed_change",
        "arbor://action/coding/workspace/release",
        "arbor://action/coding/dependency_baseline/check",
        "arbor://action/coding/review_tree/read",
        "arbor://action/coding/review_tree/search",
        "arbor://action/coding/reviewed_commit",
        "arbor://action/coding/reviewed_validation",
        "arbor://action/coding/candidate_materialization",
        "arbor://action/coding/worker_terminal/parse",
        "arbor://acp/tool/execute",
        "arbor://action/git/pr",
        "arbor://action/council/review",
        "arbor://action/consensus/decide_review"
      ]

      for resource_uri <- auto_uris do
        assert {:ok, :authorized} =
                 Arbor.Trust.authorize(agent_id, resource_uri, :execute),
               "expected coding agent to authorize #{resource_uri}"
      end

      for resource_uri <- [
            "arbor://action/mix/compile",
            "arbor://action/coding/cross_app/validate",
            "arbor://action/coding/security_regression/validate",
            "arbor://action/coding/contract_change/validate"
          ] do
        assert Arbor.Trust.effective_mode(agent_id, resource_uri, []) == :ask,
               "expected nested validator to remain approval-gated: #{resource_uri}"
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
      assert "arbor://action/coding/design_checkpoint/**" in uris
      assert "arbor://action/coding/design_council_review" in uris
      assert "arbor://action/coding/dependency_baseline/check" in uris

      refute Enum.any?(
               uris,
               &CapabilityUri.prefix_match?("arbor://approval/answer", &1)
             )

      assert Enum.any?(uris, &String.starts_with?(&1, "arbor://action/coding/reviewed_commit"))

      assert Enum.any?(
               uris,
               &String.starts_with?(&1, "arbor://action/coding/reviewed_validation")
             )

      assert "arbor://action/coding/worker_terminal/parse" in uris
      assert Enum.any?(uris, &String.starts_with?(&1, "arbor://action/git"))
      assert "arbor://action/consensus/decide_review" in uris
      refute "arbor://action/coding/produce_reviewable_change" in uris

      assert Arbor.Trust.effective_mode(
               agent_id,
               "arbor://action/coding/produce_reviewable_change",
               []
             ) == :block
    end

    test "template repo file grants mint concrete FileGuard scopes", %{lifecycle_actor: actor} do
      assert {:ok, profile} = create_agent(actor, "Repo File Tool Probe", template: "test_agent")
      agent_id = profile.agent_id
      cleanup(agent_id, actor)

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

    test "security regression: repo write shorthand mints only concrete repository scope", %{
      lifecycle_actor: actor
    } do
      character = Character.new(name: "Scoped Writer", tone: "external")

      assert {:ok, profile} =
               create_agent(actor, "Scoped Repo Writer",
                 character: character,
                 capabilities: [%{resource: "arbor://fs/write/repo"}]
               )

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      repo_root = repo_root() |> String.trim_leading("/")

      assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      uris = Enum.map(caps, & &1.resource_uri)

      assert "arbor://fs/write" in uris
      assert "arbor://fs/write/#{repo_root}/**" in uris
      refute "arbor://fs/write/**" in uris
    end

    test "authorized external registrar creates only the reviewed repo-scoped profile", %{
      lifecycle_actor: actor
    } do
      # Since ddf05e470 registration runs under the CALLER's own authority (its
      # principal must equal caller_id), so the registrar is the fixture actor.
      caller_id = actor.actor_id

      assert {:ok, _capabilities} =
               Arbor.Security.assign_role_fixture(caller_id, :external_agent_registrar)

      assert {:ok, profile, identity} =
               Arbor.Agent.register_external_agent(
                 caller_id,
                 "Scoped External Agent",
                 "external",
                 identity_verified: true,
                 actor_authority: actor.authority
               )

      cleanup(profile.agent_id, actor)

      assert identity.agent_id == profile.agent_id
      assert profile.metadata.created_by == caller_id
      assert profile.metadata.agent_type == "external"

      repo_root = repo_root() |> String.trim_leading("/")

      assert {:ok, capabilities} = Arbor.Security.list_capabilities(profile.agent_id)
      uris = Enum.map(capabilities, & &1.resource_uri)

      assert "arbor://fs/read" in uris
      assert "arbor://fs/read/#{repo_root}/**" in uris
      refute "arbor://fs/read/**" in uris
      refute "arbor://fs/write/**" in uris
    end

    test "security regression: read-only specialized templates with tenant_context do not receive workspace write grants",
         %{lifecycle_actor: actor} do
      for template <- ["test_agent", "security_auditor"] do
        workspace_root = tmp_workspace(template)
        File.mkdir_p!(workspace_root)
        on_exit(fn -> File.rm_rf(workspace_root) end)

        tenant_context =
          TenantContext.new("human_#{template}", workspace_root: workspace_root)

        assert {:ok, profile} =
                 create_agent(actor, "Tenant #{template} Probe",
                   template: template,
                   tenant_context: tenant_context
                 )

        agent_id = profile.agent_id
        cleanup(agent_id, actor)

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

    # arbor_agent does not depend on arbor_orchestrator (both L7), so in the
    # per-app test BEAM BranchSupervisor skips the Session child by design and
    # this assertion has nothing to inspect. It runs from the umbrella root,
    # where every app loads. Skip with the reason rather than fail red.
    @tag skip:
           if(Code.ensure_loaded?(Arbor.Orchestrator.Session),
             do: false,
             else: "needs arbor_orchestrator loaded — run from the umbrella root"
           )
    test "pipeline architect runtime restrictions are load-bearing through Session config", %{
      lifecycle_actor: actor,
      store: store
    } do
      assert {:ok, profile} =
               create_agent(actor, "Pipeline Architect Runtime Probe",
                 template: "pipeline_architect",
                 sandbox_level: :none
               )

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

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

      assert {:ok, ^agent_id} =
               Lifecycle.ensure_identity(agent_id, actor_authority: actor.authority)

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
                 recover_session: false,
                 task_store: store
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
               Lifecycle.start(agent_id,
                 start_heartbeat: false,
                 recover_session: false,
                 task_store: store
               )

      %{session: restored_session} = BranchSupervisor.child_pids(agent_id)
      restored_state = Arbor.Orchestrator.Session.get_state(restored_session)
      assert restored_state.config["llm_provider"] == "openai_oauth"
      assert restored_state.config["llm_model"] == "gpt-5.5"
    end

    test "pipeline architect capabilities and trust rules deny execution authority", %{
      lifecycle_actor: actor
    } do
      workspace_root = tmp_workspace("pipeline_architect_exact")
      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      assert {:ok, profile} =
               create_agent(actor, "Pipeline Architect Authority Probe",
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
      cleanup(agent_id, actor)

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

    test "security regression: malformed exact policy stops an already-running architect and revokes authority",
         %{lifecycle_actor: actor, store: store} do
      assert {:ok, profile} =
               create_agent(actor, "Corrupt Policy Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      assert {:ok, _supervisor} =
               Lifecycle.start(agent_id,
                 start_heartbeat: false,
                 recover_session: false,
                 task_store: store
               )

      corrupted =
        put_in(profile.metadata["exact_template_policy"]["digest"], String.duplicate("0", 64))

      assert :ok = Arbor.Agent.ProfileStore.store_profile(corrupted)

      assert {:error, _reason} =
               Lifecycle.start(agent_id, start_heartbeat: false, task_store: store)

      assert_eventually(fn -> is_nil(BranchSupervisor.whereis(agent_id)) end)
      assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
      assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
    end

    test "legacy Pipeline Architect profiles migrate to an exact snapshot before activation", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} =
               create_agent(actor, "Legacy Architect Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      legacy = %{profile | metadata: Map.delete(profile.metadata, "exact_template_policy")}
      assert :ok = Arbor.Agent.ProfileStore.store_profile(legacy)

      assert {:ok, ^agent_id} =
               Lifecycle.ensure_identity(agent_id, actor_authority: actor.authority)

      assert {:ok, migrated} = Lifecycle.restore(agent_id)
      assert %{} = migrated.metadata["exact_template_policy"]
    end

    test "security regression: a missing exact template fails closed and removes authority", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} =
               create_agent(actor, "Missing Template Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      assert :ok =
               Arbor.Agent.ProfileStore.store_profile(%{
                 profile
                 | template: "missing_pipeline_architect"
               })

      assert {:error, _reason} =
               Lifecycle.ensure_identity(agent_id, actor_authority: actor.authority)

      assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
      assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
    end

    test "security regression: a changed exact template fails closed and removes authority", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} =
               create_agent(actor, "Changed Template Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

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

      assert {:error, _reason} =
               Lifecycle.ensure_identity(agent_id, actor_authority: actor.authority)

      assert {:ok, :suspended} = Arbor.Security.identity_status(agent_id)
      assert {:ok, []} = Arbor.Security.list_capabilities(agent_id)
    end

    test "security regression: exact reconciliation revokes capabilities widened after creation",
         %{lifecycle_actor: actor} do
      assert {:ok, profile} =
               create_agent(actor, "Widened Capability Probe", template: "pipeline_architect")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      assert {:ok, _capability} =
               Arbor.Security.grant_fixture(principal: agent_id, resource: "arbor://shell/exec")

      assert {:ok, ^agent_id} =
               Lifecycle.ensure_identity(agent_id, actor_authority: actor.authority)

      assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      refute "arbor://shell/exec" in Enum.map(caps, & &1.resource_uri)
    end

    test "security regression: creation fails when a declared trust preset cannot be stored",
         %{lifecycle_actor: actor, trust_supervisor: trust_supervisor} do
      before_ids = Lifecycle.list_agents() |> Enum.map(& &1.agent_id) |> MapSet.new()

      stop_trust_child(trust_supervisor, Arbor.Trust.Manager)
      stop_trust_child(trust_supervisor, TrustStore)

      result =
        try do
          create_agent(actor, "Unstored Restrictive Template Probe",
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

    test "a template WITHOUT a trust_preset is not forced to :block by this path", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} =
               create_agent(actor, "Plain Agent Probe", template: "conversationalist")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      assert {:ok, tp} = TrustStore.get_profile(agent_id)

      # Keeps the default (:cautious) profile — baseline :ask, NOT forced to
      # :block. Proves the preset path only fires when a preset is declared.
      assert tp.baseline == :ask
      refute tp.baseline == :block
    end

    test "non-exact template creation does not require an umbrella cwd", %{lifecycle_actor: actor} do
      original_cwd = File.cwd!()
      isolated_cwd = tmp_workspace("non_exact_cwd")
      File.mkdir_p!(isolated_cwd)

      on_exit(fn ->
        File.cd!(original_cwd)
        File.rm_rf(isolated_cwd)
      end)

      File.cd!(isolated_cwd)

      assert {:ok, profile} =
               create_agent(actor, "Non-exact CWD Probe", template: "conversationalist")

      cleanup(profile.agent_id, actor)
    end
  end

  describe "concurrent lifecycle start security regression" do
    test "coalesced concurrent starts share one intent, one bootstrap, and one branch pid", %{
      lifecycle_actor: actor,
      store: store
    } do
      assert {:ok, profile} =
               create_agent(actor, "Concurrent Bootstrap Probe", template: "test_agent")

      agent_id = profile.agent_id
      cleanup(agent_id, actor)

      assert principal_bootstraps(agent_id) == []

      supervisor = Process.whereis(Arbor.Agent.Supervisor)
      assert is_pid(supervisor)
      :ok = :sys.suspend(supervisor)

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Lifecycle.start(agent_id,
              start_heartbeat: false,
              recover_session: false,
              task_store: store
            )
          end)
        end

      try do
        # Admission joins same-target/fingerprint callers onto one live intent
        # before lifecycle effects. Two waiters prove both callers are parked
        # on that single intent — not two independent start paths.
        assert_eventually(fn ->
          case live_runtime_admission(store, agent_id) do
            %{waiter_count: 2} -> true
            _ -> false
          end
        end)

        # Only the bound worker issues branch authority; coalesced joiners do not.
        assert_eventually(fn ->
          case principal_bootstraps(agent_id) do
            [%{purpose: :session}] -> true
            _ -> false
          end
        end)
      after
        :ok = :sys.resume(supervisor)
      end

      assert [{:ok, winner}, {:ok, winner}] = Task.await_many(tasks, 10_000)
      assert is_pid(winner)

      assert_eventually(fn ->
        case principal_bootstraps(agent_id) do
          [%{purpose: :session, status: status}] when status in [:unclaimed, :claimed] -> true
          _ -> false
        end
      end)
    end
  end

  describe "destroy tears down leftover principal authority" do
    @tag :security_regression
    test "destroy removes trust profile, capabilities, identity, and signing key", %{
      lifecycle_actor: actor
    } do
      assert {:ok, profile} =
               create_agent(actor, "Destroy Authority Probe", template: "test_agent")

      agent_id = profile.agent_id

      assert {:ok, _trust} = Arbor.Trust.get_trust_profile(agent_id)
      assert {:ok, caps} = Arbor.Security.list_capabilities(agent_id)
      assert caps != []

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute", :execute)

      assert {:ok, :active} = Arbor.Security.identity_status(agent_id)
      assert {:ok, _pub} = Arbor.Security.lookup_public_key(agent_id)

      assert :ok = Lifecycle.destroy(agent_id, actor_authority: actor.authority)

      assert {:error, :not_found} = Arbor.Trust.get_trust_profile(agent_id)
      assert {:error, :not_found} = Arbor.Security.identity_status(agent_id)
      assert {:error, :not_found} = Arbor.Security.lookup_public_key(agent_id)

      authorize =
        Arbor.Security.authorize(agent_id, "arbor://orchestrator/execute", :execute)

      refute match?({:ok, :authorized}, authorize)
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

  # Test-only observation of TaskStore runtime-admission shape for agent_id.
  # Returns %{intent_id:, waiter_count:} when exactly one live intent exists.
  defp live_runtime_admission(store, agent_id) do
    case :sys.get_state(store) do
      %{runtime_admission_intents: intents, runtime_admission_waiters: waiters} ->
        case Map.get(intents, agent_id) do
          %{intent_id: intent_id} when is_binary(intent_id) ->
            bucket = Map.get(waiters, intent_id, %{})

            count =
              cond do
                is_map(bucket) -> map_size(bucket)
                is_list(bucket) -> length(bucket)
                true -> 0
              end

            %{
              intent_id: intent_id,
              waiter_count: count
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
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

  defp create_agent(actor, name, opts) do
    Lifecycle.create(name, Keyword.put(opts, :actor_authority, actor.authority))
  end

  # on_exit runs after the test process exits, when the test's authority is
  # gone; destroy_agent_fixture/2 reopens the shared actor in the callback.
  defp cleanup(agent_id, actor) do
    on_exit(fn -> Arbor.Agent.destroy_agent_fixture(agent_id, actor) end)
  end
end
