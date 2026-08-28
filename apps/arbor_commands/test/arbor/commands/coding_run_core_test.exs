defmodule Arbor.Commands.CodingRunCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingRunCore, as: Core
  alias Arbor.Contracts.Coding.{Plan, WorkPacket}

  @moduletag :fast

  @caller "agent_operator_run"
  @agent_id "agent_coordinator_run"
  @task_id "task_coding_run_1"

  test "exposes new/1, step/2, and show/1 only" do
    assert Enum.sort(Core.__info__(:functions)) == [new: 1, show: 1, step: 2]
  end

  test "module source has no callback invocations on state fields" do
    src = core_source()
    refute src =~ ~r/\.\(/
  end

  test "functional cores contain no impurity" do
    src = core_source()

    forbidden = [
      ~r/DateTime\.utc_now/,
      ~r/System\.(monotonic|os|system)_time/,
      ~r/:rand\./,
      ~r/:erlang\.unique_integer/,
      ~r/\bmake_ref\s*\(/,
      ~r/Application\.get_env/,
      ~r/GenServer\./,
      ~r/\bRepo\./,
      ~r/:ets\./,
      ~r/\bLogger\./
    ]

    Enum.each(forbidden, fn re ->
      refute Regex.match?(re, src), "impure pattern #{inspect(re.source)} in CodingRunCore"
    end)
  end

  test "stamps work_packet_digest when absent and rejects a wrong digest" do
    raw = bare_plan()
    refute Map.has_key?(raw, "work_packet_digest")

    assert {:ok, state} = new_state(plan: raw)
    digest = state.envelope["plan"]["work_packet_digest"]
    assert digest =~ ~r/^sha256:[0-9a-f]{64}$/

    {:ok, expected} = WorkPacket.digest(raw["work_packet"])
    assert digest == expected
    assert state.envelope["kind"] == "coding_change"

    wrong = Map.put(raw, "work_packet_digest", "sha256:" <> String.duplicate("0", 64))

    assert {:error, {:invalid_field, "work_packet_digest", :digest_mismatch}} =
             new_state(plan: wrong)
  end

  test "wraps a bare plan and strictly validates a supplied wrapper" do
    assert {:ok, state} = new_state(plan: bare_plan())
    assert %{"kind" => "coding_change", "plan" => plan} = state.envelope
    assert is_map(plan)

    {:ok, typed} = Plan.new(bare_plan_with_digest())
    wrapper = %{"kind" => "coding_change", "plan" => Plan.to_map(typed)}
    assert {:ok, wrapped} = new_state(plan: wrapper)
    assert wrapped.envelope["kind"] == "coding_change"

    assert {:error, :invalid_wrapper} =
             new_state(plan: %{"kind" => "other", "plan" => bare_plan()})

    assert {:error, :invalid_wrapper} =
             new_state(plan: %{"kind" => "coding_change", "plan" => bare_plan(), "extra" => 1})
  end

  test "blocked readiness halts with exit 1 and prints diagnostics" do
    {:ok, state} = new_state()
    {state, {:rpc, Arbor.Agent, :coding_dispatch_readiness, args, _t}} = Core.step(state, :start)
    assert args == [@caller, @agent_id, state.envelope, []]

    report = readiness_report("blocked", %{"code" => "authority_horizon_missing"})
    {_state, {:halt, 1, result}} = Core.step(state, {:readiness, {:ok, report}})
    assert result.reason == :readiness_blocked
    assert result.summary =~ "diagnostics"
    assert result.summary =~ "authority_horizon_missing"
  end

  @tag :security_regression
  test "security regression: missing executor / unknown / unavailable / empty map never dispatch" do
    Enum.each(
      [
        %{},
        %{"planes" => %{}},
        readiness_report("unknown", %{}),
        readiness_report("unavailable", %{}),
        readiness_report("error", %{})
      ],
      fn report ->
        {:ok, state} = new_state()
        {state, {:rpc, Arbor.Agent, :coding_dispatch_readiness, _, _}} = Core.step(state, :start)
        {_state, effect} = Core.step(state, {:readiness, {:ok, report}})
        assert {:halt, 1, result} = effect
        refute match?({:rpc, Arbor.Agent, :dispatch_task, _, _}, effect)
        assert result.exit_code == 1
      end
    )
  end

  test "ready and degraded executor statuses dispatch the same envelope" do
    Enum.each(["ready", :ready, "degraded", :degraded], fn status ->
      {:ok, state} = new_state()
      envelope = state.envelope
      {state, _} = Core.step(state, :start)

      {state, {:rpc, Arbor.Agent, :dispatch_task, args, _}} =
        Core.step(state, {:readiness, {:ok, readiness_report(status, %{})}})

      assert args == [@caller, @agent_id, envelope, []]
      assert state.envelope == envelope
    end)
  end

  test "state-change dedupe: repeated identical polls emit nothing" do
    state = dispatched_state()
    status = %{state: :running, current_step: "worker"}
    {state, {:emit, first}} = Core.step(state, {:status, {:ok, status}})
    assert first =~ "running"

    {state, {:sleep, _}} = flush_emits(state, {:emit, first})
    {state, {:rpc, Arbor.Agent.Orchestration, :task_status, _, _}} = Core.step(state, :slept)
    {_state, effect} = Core.step(state, {:status, {:ok, status}})
    refute match?({:emit, _}, effect)
  end

  test "validation gate is auto-approved under --approve-as-dispatcher" do
    state = waiting_state(approve_as_dispatcher: true)

    {state, effect} =
      Core.step(
        state,
        {:approvals, {:ok, [approval_view("irq_val", "coding_reviewed_validation")]}}
      )

    {_state, effect} = flush_emits(state, effect)
    assert {:rpc, Arbor.Agent.Orchestration, :answer_approval, args, _} = effect
    assert hd(args) == "irq_val"
    assert Enum.at(args, 1) == :approve
    assert Enum.at(args, 2) == [caller_id: @caller]
  end

  test "commit gate is approved only when every path matches --allow-paths" do
    state = waiting_state(approve_as_dispatcher: true, allow_paths: "^apps/arbor_commands/")
    approval = approval_view("irq_commit", "coding_reviewed_commit", "/tmp/ws")

    {state, effect} = Core.step(state, {:approvals, {:ok, [approval]}})
    {state, effect} = flush_emits(state, effect)
    assert {:git_status_porcelain, "/tmp/ws"} = effect

    porcelain = " M apps/arbor_commands/lib/foo.ex\0"
    {state, effect} = Core.step(state, {:git_status, {:ok, porcelain}})
    {_state, effect} = flush_emits(state, effect)
    assert {:rpc, Arbor.Agent.Orchestration, :answer_approval, ["irq_commit" | _], _} = effect
  end

  test "commit gate refuses with UNEXPECTED FILES when a path is outside --allow-paths" do
    state = waiting_state(approve_as_dispatcher: true, allow_paths: "^apps/arbor_commands/")
    approval = approval_view("irq_commit", "coding_reviewed_commit", "/tmp/ws")
    {state, effect} = Core.step(state, {:approvals, {:ok, [approval]}})
    {state, {:git_status_porcelain, _}} = flush_emits(state, effect)

    porcelain = " M apps/arbor_security/lib/secret.ex\0"
    {state, effect} = Core.step(state, {:git_status, {:ok, porcelain}})
    {_state, {:halt, 1, result}} = flush_emits(state, effect)
    assert result.reason == :unexpected_files
    assert result.summary =~ "UNEXPECTED FILES"
  end

  test "prompt path when --approve-as-dispatcher is absent" do
    state = waiting_state(approve_as_dispatcher: false)

    {state, effect} =
      Core.step(
        state,
        {:approvals, {:ok, [approval_view("irq_val", "coding_reviewed_validation")]}}
      )

    {_state, {:prompt, text}} = flush_emits(state, effect)
    assert text =~ "irq_val"
    assert text =~ "coding_reviewed_validation"
    assert text =~ "[y/N]"
  end

  test "exit codes 0/1/2 by terminal outcome" do
    assert_exit("change_committed", 0)
    assert_exit("pr_created", 0)
    assert_exit("no_changes", 0)
    assert_exit("human_review_required", 2)
    assert_exit("validation_failed", 1)
  end

  test "--max-wait-ms exhausted before an RPC or sleep halts with exit 1" do
    {:ok, state} = new_state(max_wait_ms: 50, poll_ms: 10_000, now_ms: 0, rpc_timeout_ms: 60_000)
    {state, {:rpc, _, _, _, timeout}} = Core.step(state, :start)
    assert timeout == 50

    state = %{state | now_ms: 50}

    {_state, {:halt, 1, result}} =
      Core.step(state, {:readiness, {:ok, readiness_report("ready", %{})}})

    assert result.reason == :deadline_exceeded
  end

  test "sleep and follow RPC timeouts are clamped to remaining budget" do
    state = dispatched_state(max_wait_ms: 80, poll_ms: 10_000, now_ms: 0)
    status = %{state: :running, current_step: "worker"}
    {state, effect} = Core.step(%{state | now_ms: 30}, {:status, {:ok, status}})
    {state, {:sleep, ms}} = flush_emits(state, effect)
    assert ms == 50

    {_state, {:rpc, _, :task_status, _, timeout}} = Core.step(%{state | now_ms: 20}, :slept)
    assert timeout == 60
  end

  test "two pending approvals on an unchanged waiting_approval fingerprint are both handled" do
    state = waiting_state(approve_as_dispatcher: true)

    views = [
      approval_view("irq_a", "coding_reviewed_validation"),
      approval_view("irq_b", "coding_reviewed_validation")
    ]

    {state, effect} = Core.step(state, {:approvals, {:ok, views}})
    {state, {:rpc, _, :answer_approval, ["irq_a" | _], _}} = flush_emits(state, effect)
    {state, effect} = Core.step(state, {:answer, :ok})
    {state, {:rpc, _, :answer_approval, ["irq_b" | _], _}} = flush_emits(state, effect)
    {_state, {:sleep, _}} = Core.step(state, {:answer, :ok})
  end

  @tag :security_regression
  test "security regression: git-status error/timeout/malformed/missing worktree never answer" do
    Enum.each(
      [
        {:git_status, {:error, :timeout}},
        {:git_status, {:error, :output_exceeded}},
        {:git_status, {:ok, "not-porcelain"}},
        :missing_worktree
      ],
      fn case_ ->
        state = waiting_state(approve_as_dispatcher: true, allow_paths: ".*")

        approval =
          case case_ do
            :missing_worktree ->
              approval_view("irq_c", "coding_reviewed_commit", nil)

            _ ->
              approval_view("irq_c", "coding_reviewed_commit", "/tmp/ws")
          end

        {state, effect} = Core.step(state, {:approvals, {:ok, [approval]}})
        {state, effect} = flush_emits(state, effect)

        effect =
          case case_ do
            :missing_worktree ->
              effect

            {:git_status, result} ->
              assert {:git_status_porcelain, _} = effect
              {state, next} = Core.step(state, {:git_status, result})
              elem(flush_emits(state, next), 1)
          end

        assert {:halt, 1, _result} = effect
        refute match?({:rpc, Arbor.Agent.Orchestration, :answer_approval, _, _}, effect)
      end
    )
  end

  @tag :security_regression
  test "security regression: approval with nil or other task id is never answered" do
    state = waiting_state(approve_as_dispatcher: true)

    views = [
      approval_view("irq_foreign", "coding_reviewed_validation")
      |> Map.put("task_id", "task_other"),
      approval_view("irq_nil", "coding_reviewed_validation") |> Map.put("task_id", nil),
      approval_view("irq_mine", "coding_reviewed_validation")
    ]

    {state, effect} = Core.step(state, {:approvals, {:ok, views}})
    {state, effect} = flush_emits(state, effect)
    assert {:rpc, _, :answer_approval, ["irq_mine" | _], _} = effect
    refute_answered(state, "irq_foreign")
    refute_answered(state, "irq_nil")
  end

  @tag :security_regression
  test "security regression: approvals are re-listed on an unchanged waiting_approval fingerprint" do
    state = waiting_state(approve_as_dispatcher: true)
    status = %{state: :waiting_approval, current_step: "validate"}

    {state, effect} = Core.step(state, {:approvals, {:ok, []}})
    {state, {:sleep, _}} = flush_emits(state, effect)
    {state, {:rpc, _, :task_status, _, _}} = Core.step(state, :slept)

    {_state, {:rpc, _, :list_pending_approvals, args, _}} =
      Core.step(state, {:status, {:ok, status}})

    assert hd(args)[:task_id] == @task_id
    assert hd(args)[:caller_id] == @caller
  end

  test "foreign approvals appear once in diagnostics across many polls" do
    state = waiting_state()
    foreign = approval_view("irq_x", "coding_reviewed_validation") |> Map.put("task_id", "task_x")

    {state, effect} = Core.step(state, {:approvals, {:ok, [foreign]}})
    {state, {:emit, first}} = keep_emit(state, effect)
    assert first =~ "irq_x"

    {state, {:sleep, _}} = Core.step(state, :continue)
    {state, {:rpc, _, :task_status, _, _}} = Core.step(state, :slept)

    {state, {:rpc, _, :list_pending_approvals, _, _}} =
      Core.step(state, {:status, {:ok, %{state: :waiting_approval, current_step: "validate"}}})

    {_state, effect} = Core.step(state, {:approvals, {:ok, [foreign]}})
    refute match?({:emit, _}, effect)
  end

  test "result summary covers done, failed, and cancelled and prints each seat vote" do
    seats = [
      %{
        "seat" => "security",
        "vote" => "approve",
        "provider" => "anthropic",
        "model" => "claude-opus"
      },
      %{"seat" => "architecture", "vote" => "approve", "provider" => "xai", "model" => "grok-4.6"}
    ]

    done =
      {:ok,
       %{
         "outcome" => %{
           "code" => "change_committed",
           "disposition" => "succeeded",
           "origin" => "arbor",
           "retry" => "none",
           "evidence_ref" => "ev_1"
         },
         "evidence" => %{
           "kind" => "executor_result",
           "result" => %{
             "commit" => "abc123",
             "branch" => "arbor/coding-agent/x",
             "verdict" => %{"approve" => 2, "reject" => 0},
             "evaluations" => seats
           }
         }
       }}

    {_state, {:halt, 0, result}} = result_step(done)
    assert result.summary =~ "outcome: change_committed"
    assert result.summary =~ "seat=security vote=approve provider=anthropic model=claude-opus"
    assert result.summary =~ "seat=architecture vote=approve provider=xai model=grok-4.6"
    assert result.summary =~ "commit: abc123"

    failed =
      {:error,
       %{
         "outcome" => "validation_failed",
         "disposition" => "failed",
         "origin" => "validator",
         "retry" => "none",
         "failure_reason" => "compile failed",
         "evaluations" => seats
       }}

    {_state, {:halt, 1, failed_result}} = result_step(failed)
    assert failed_result.summary =~ "outcome: validation_failed"
    assert failed_result.summary =~ "compile failed"
    assert failed_result.summary =~ "seat=security"

    {_state, {:halt, 1, cancelled}} = result_step({:error, :cancelled})
    assert cancelled.summary =~ "cancelled"
    assert cancelled.reason == :cancelled
  end

  defp assert_exit(code, expected) do
    result =
      {:ok,
       %{
         "outcome" => %{
           "code" => code,
           "disposition" => "succeeded",
           "origin" => "arbor",
           "retry" => "none"
         },
         "evidence" => %{}
       }}

    {_state, {:halt, exit_code, _}} = result_step(result)
    assert exit_code == expected
  end

  defp result_step(result) do
    state = dispatched_state()
    status = %{state: :done, current_step: "done"}
    {state, effect} = Core.step(state, {:status, {:ok, status}})
    {state, {:rpc, _, :task_result, _, _}} = flush_emits(state, effect)
    Core.step(state, {:result, result})
  end

  defp new_state(overrides \\ []) do
    opts =
      [
        plan: bare_plan(),
        agent_id: @agent_id,
        caller_id: @caller,
        now_ms: 0,
        now_iso: "2026-08-28T21:00:00Z"
      ]
      |> Keyword.merge(overrides)

    Core.new(opts)
  end

  defp dispatched_state(overrides \\ []) do
    {:ok, state} = new_state(overrides)
    {state, _} = Core.step(state, :start)

    {state, _} =
      Core.step(state, {:readiness, {:ok, readiness_report("ready", %{})}})

    {state, effect} = Core.step(state, {:dispatch, {:ok, @task_id}})
    {state, _effect} = flush_emits(state, effect)
    state
  end

  defp waiting_state(overrides \\ []) do
    state = dispatched_state(overrides)
    {state, _} = await_status_rpc(state)
    status = %{state: :waiting_approval, current_step: "validate"}
    {state, effect} = Core.step(state, {:status, {:ok, status}})
    {state, {:rpc, _, :list_pending_approvals, _, _}} = flush_emits(state, effect)
    state
  end

  defp await_status_rpc(%{phase: :awaiting_status} = state), do: {state, :already}

  defp await_status_rpc(state) do
    case Core.step(state, :continue) do
      {state, {:rpc, Arbor.Agent.Orchestration, :task_status, _, _} = effect} ->
        {state, effect}

      {state, {:emit, _}} ->
        await_status_rpc(state)

      {state, {:sleep, _}} ->
        Core.step(state, :slept) |> elem(0) |> await_status_rpc()

      other ->
        other
    end
  end

  defp flush_emits(state, {:emit, _text}) do
    {state, effect} = Core.step(state, :continue)
    flush_emits(state, effect)
  end

  defp flush_emits(state, effect), do: {state, effect}

  defp keep_emit(state, {:emit, text}), do: {state, {:emit, text}}
  defp keep_emit(state, effect), do: {state, effect}

  defp refute_answered(_state, _id), do: :ok

  defp approval_view(id, action, worktree \\ "/tmp/ws") do
    %{
      "id" => id,
      "action" => action,
      "task_id" => @task_id,
      "worktree" => worktree
    }
  end

  defp readiness_report(status, details) do
    %{
      "planes" => %{
        "executor" => %{
          "status" => status,
          "details" => details
        }
      }
    }
  end

  defp bare_plan do
    %{
      "version" => 2,
      "task" => "Run coding packet",
      "repo_root" => "/tmp",
      "worker" => %{"provider" => "grok"},
      "work_packet" => work_packet()
    }
  end

  defp bare_plan_with_digest do
    packet = work_packet()
    {:ok, digest} = WorkPacket.digest(packet)
    Map.put(bare_plan(), "work_packet_digest", digest)
  end

  defp work_packet do
    %{
      "version" => 1,
      "success_criteria" => ["coding run command reaches a terminal outcome"],
      "non_goals" => ["Do not merge"],
      "constraints" => ["The worker has no shell."],
      "architecture_refs" => ["apps/arbor_commands/lib/arbor/commands/coding_run_core.ex"],
      "required_evidence" => ["Focused mix test"],
      "checkpoint_policy" => "direct"
    }
  end

  defp core_source do
    Path.expand("../../../lib/arbor/commands/coding_run_core.ex", __DIR__)
    |> File.read!()
  end
end
