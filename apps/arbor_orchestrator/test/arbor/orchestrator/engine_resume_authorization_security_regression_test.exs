defmodule Arbor.Orchestrator.EngineResumeAuthorizationSecurityRegressionTest do
  @moduledoc """
  Security regression test for the engine's resume-time capability gate
  (`Arbor.Orchestrator.Engine.maybe_revalidate_capabilities/2`).

  ## The bug class — "security ceilings fail open silently"

  On `Engine.run/2` with a checkpoint (resume), the engine re-checks that the
  resuming agent still holds `arbor://orchestrator/execute` before re-entering
  the pipeline. That check used to be guarded by a module-presence test:

      if agent_id && Code.ensure_loaded?(Arbor.Security) &&
           function_exported?(Arbor.Security, :authorize, 3) do
        case apply(Arbor.Security, :authorize, [...]) do ... end
      else
        :ok            # <-- FAIL OPEN: gate silently skipped
      end
      rescue _ -> :ok  # <-- FAIL OPEN: any error swallowed to :ok

  If the guard ever evaluated false (arbor_security not loaded, refactor renames
  the function, hot-reload window) the authorize was SKIPPED and resume proceeded
  unauthorized. The surrounding `rescue _ -> :ok` was a second fail-open: an
  exception during the check passed instead of denying.

  The fix makes arbor_security a hard dep and calls
  `Arbor.Security.authorize/3` DIRECTLY (no module-presence guard, no
  swallow-to-:ok rescue). The gate now ALWAYS fires whenever an `agent_id` is
  present.

  ## What this test does and does NOT guarantee — read before "simplifying" it

  This test asserts behaviorally via the public `Arbor.Orchestrator.run/2` API
  that the resume gate FIRES: an agent lacking `arbor://orchestrator/execute`
  is DENIED (`{:error, {:unauthorized_resume, _}}`); a granted agent resumes.

  Honesty note (verified 2026-06-17 by reintroducing the old guarded+rescue
  body and re-running this test — it still PASSED): this test does NOT, on its
  own, fail on the pre-fix code in a normal test environment. The two fail-open
  branches are simply not reachable here:
    * the `function_exported?(Arbor.Security, :authorize, 3)` guard is always
      TRUE in-test (arbor_security is loaded), so the `else -> :ok` skip never
      ran; and
    * `Arbor.Security.authorize/3` is fail-closed-RETURNING — it returns
      `{:error, :unauthorized}` for ungranted/nil/malformed principals and
      never raises — so the `rescue _ -> :ok` swallow never fired.
  The fail-open was only reachable in a DEGRADED runtime (arbor_security not
  loaded / a hot-reload window / a future refactor making authorize raise),
  which can't be reproduced in-process without re-adding the very indirection
  seam the fix removes.

  So the regression guard for THIS bug is twofold, and both halves matter:
    1. THE COMPILER — arbor_security is now a hard dep called directly, so a
       future refactor that drops or renames the authorize call is a compile
       error. This is the primary, strongest guard for the likeliest drift.
    2. THIS behavioral test — locks in that the gate is wired and DENIES an
       unauthorized resume, catching a logic inversion or gate removal that
       still compiles.
  Do not delete this as "redundant with the compiler": #1 catches a removed
  call, #2 catches a gate that compiles but stops denying.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.TestCapabilities

  # Single function-exec node so resume has somewhere to go after the gate.
  @resume_dot """
  digraph ResumeGate {
    graph [goal="resume-time capability re-validation"]
    start [shape=Mdiamond]
    work [type="exec", target="function"]
    done [shape=Msquare]
    start -> work -> done
  }
  """

  defp logs_root do
    Path.join(
      System.tmp_dir!(),
      "arbor_resume_authz_regress_#{System.unique_integer([:positive])}"
    )
  end

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    journal_name = :"resume_authz_journal_#{suffix}"

    start_supervised!(
      {RunJournal, name: journal_name, ets_table: :"resume_authz_hot_#{suffix}", backend: nil}
    )

    %{journal_opts: [server: journal_name]}
  end

  # Run once to write a signed checkpoint, then stage the lifecycle claim that
  # atomic resume admission now requires. The seed run has authorization off,
  # so the capability gate is exercised only by the subsequent resume.
  defp seed_signed_checkpoint(
         root,
         private_key,
         run_id,
         principal,
         journal_opts
       ) do
    ckpt_path = Path.join(root, "checkpoint.json")

    {:ok, _} =
      Arbor.Orchestrator.run(@resume_dot,
        logs_root: root,
        run_id: run_id,
        authorization: false,
        identity_private_key: private_key,
        agent_id: principal,
        execution_principal: principal,
        journal_opts: journal_opts,
        function_handler: fn _args -> {:ok, %{ran: true}} end
      )

    assert File.exists?(ckpt_path), "engine should have written a checkpoint to resume from"

    assert {:ok, %Record{} = finished} =
             RunJournal.get_record(run_id, journal_opts)

    assert :ok =
             RunJournal.put(
               %Record{
                 finished
                 | status: :recovering,
                   finished_at: nil,
                   duration_ms: nil,
                   failure_reason: nil,
                   owner_node: node(),
                   spawning_pid: nil
               },
               journal_opts
             )

    ckpt_path
  end

  test "resume DENIES an agent that lacks arbor://orchestrator/execute (gate fires)", ctx do
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)

    private_key = :crypto.strong_rand_bytes(32)

    # This agent is NOT granted the capability anywhere (test_helper grants a
    # fixed allowlist; this id is not in it and we don't grant it).
    ungranted = "agent_resume_authz_denied_#{System.unique_integer([:positive])}"
    run_id = "resume_authz_denied_#{System.unique_integer([:positive])}"

    ckpt_path =
      seed_signed_checkpoint(root, private_key, run_id, ungranted, ctx.journal_opts)

    result =
      Arbor.Orchestrator.run(@resume_dot,
        logs_root: root,
        resume_from: ckpt_path,
        run_id: run_id,
        authorization: false,
        identity_private_key: private_key,
        agent_id: ungranted,
        execution_principal: ungranted,
        journal_opts: ctx.journal_opts,
        function_handler: fn _args -> {:ok, %{ran: true}} end
      )

    assert match?({:error, {:unauthorized_resume, _}}, result),
           "resume capability gate failed open: an agent lacking " <>
             "arbor://orchestrator/execute was allowed to resume. Got: #{inspect(result)}"
  end

  test "resume ALLOWS an agent that holds arbor://orchestrator/execute (gate passes through)",
       ctx do
    root = logs_root()
    on_exit(fn -> File.rm_rf(root) end)

    private_key = :crypto.strong_rand_bytes(32)

    granted = "agent_resume_authz_granted_#{System.unique_integer([:positive])}"
    run_id = "resume_authz_granted_#{System.unique_integer([:positive])}"
    :ok = TestCapabilities.grant_orchestrator_access(granted)
    on_exit(fn -> TestCapabilities.revoke_all(granted) end)

    ckpt_path =
      seed_signed_checkpoint(root, private_key, run_id, granted, ctx.journal_opts)

    assert {:ok, _result} =
             Arbor.Orchestrator.run(@resume_dot,
               logs_root: root,
               resume_from: ckpt_path,
               run_id: run_id,
               authorization: false,
               identity_private_key: private_key,
               agent_id: granted,
               execution_principal: granted,
               journal_opts: ctx.journal_opts,
               function_handler: fn _args -> {:ok, %{ran: true}} end
             )
  end
end
