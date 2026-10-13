defmodule Arbor.Commands.PipelineArchitectSessionRestrictionsTest do
  @moduledoc """
  Moved from `arbor_agent` `trust_preset_apply_test.exs`.

  `arbor_agent` cannot depend on `arbor_orchestrator` (both L7), so the
  Session-starting assertion was skip-tagged and never ran. This L8 app
  depends on both and can load Session.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Agent.{BranchSupervisor, Lifecycle}
  alias Arbor.Agent.Test.RuntimeAdmissionTopology
  alias Arbor.Commands.Test.SessionLifecycleHelpers, as: Helpers
  alias Arbor.Orchestrator.Session

  setup_all do
    Helpers.require_agent_test_support!()
    prev = Helpers.setup_security_flags!()
    Helpers.start_runtime!()

    {:ok, principal} = Arbor.Agent.open_lifecycle_actor_fixture()

    on_exit(fn ->
      Arbor.Agent.close_lifecycle_actor_fixture(principal)
      Helpers.restore_security_flags!(prev)
    end)

    {:ok, lifecycle_principal: principal}
  end

  setup %{lifecycle_principal: principal} do
    Helpers.start_runtime!()
    {:ok, actor} = Arbor.Agent.reopen_lifecycle_actor_fixture(principal)
    %{lifecycle_actor: actor}
  end

  test "pipeline architect runtime restrictions are load-bearing through Session config", %{
    lifecycle_actor: actor
  } do
    %{store: store} = RuntimeAdmissionTopology.start_fixed_production!()

    assert {:ok, profile} =
             Helpers.create_agent(actor, "Pipeline Architect Runtime Probe",
               template: "pipeline_architect",
               sandbox_level: :none
             )

    agent_id = profile.agent_id
    Helpers.cleanup(agent_id, actor)

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
    umbrella_root = Helpers.umbrella_root_from(__DIR__)
    on_exit(fn -> File.cd!(original_cwd) end)
    File.cd!(Path.join(umbrella_root, "apps"))

    assert {:ok, ^agent_id} =
             Lifecycle.ensure_identity(agent_id, actor_authority: actor.authority)

    File.cd!(original_cwd)

    assert {:ok, _supervisor} =
             Lifecycle.start(agent_id,
               actor_authority: actor.authority,
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

    session_state = Session.get_state(session)
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
               actor_authority: actor.authority,
               start_heartbeat: false,
               recover_session: false,
               task_store: store
             )

    %{session: restored_session} = BranchSupervisor.child_pids(agent_id)
    restored_state = Session.get_state(restored_session)
    assert restored_state.config["llm_provider"] == "openai_oauth"
    assert restored_state.config["llm_model"] == "gpt-5.5"
  end
end
