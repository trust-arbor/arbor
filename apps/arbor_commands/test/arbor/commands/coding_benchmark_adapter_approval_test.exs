defmodule Arbor.Commands.CodingBenchmarkAdapterApprovalTest do
  use Arbor.Commands.CodingBenchmarkAdapterCase, async: false

  alias Arbor.Commands.CodingBenchmark.LegacyAdapter
  alias Arbor.Signals

  setup do
    ensure_signals!()
    :ok
  end

  test "aggregates rework-then-approval cycles from correlated interaction signals" do
    requests = unique_requests!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      __MODULE__.ApprovalHistoryExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:ok, success_result()}
    )

    assert {:ok, envelope} = LegacyAdapter.run(requests.legacy)

    assert envelope["observations"]["approval"] == %{
             "count" => 2,
             "requested" => true,
             "required" => true,
             "resumed" => true,
             "status" => "approved"
           }
  end

  test "ignores other task correlation ids and non-approval interactions" do
    requests = unique_requests!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      __MODULE__.IsolatedApprovalExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:ok, success_result()}
    )

    assert {:ok, envelope} = LegacyAdapter.run(requests.legacy)

    assert envelope["observations"]["approval"] == %{
             "count" => 1,
             "requested" => true,
             "required" => true,
             "resumed" => true,
             "status" => "approved"
           }
  end

  test "falls back to terminal approval_request_id inference when history is empty" do
    requests = unique_requests!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      CapturingLegacyExecutor
    )

    result =
      success_result()
      |> put_in(["payload", "report", "approval_request_id"], "irq_terminalonlyabcdef")

    Application.put_env(:arbor_commands, :coding_benchmark_legacy_test_reply, {:ok, result})

    assert {:ok, envelope} = LegacyAdapter.run(requests.legacy)

    assert envelope["observations"]["approval"] == %{
             "count" => 1,
             "requested" => true,
             "required" => true,
             "resumed" => true,
             "status" => "approved"
           }
  end

  test "nil cleanup and ownership tokens project defaults rather than the string nil" do
    requests = unique_requests!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      CapturingLegacyExecutor
    )

    result =
      success_result()
      |> put_in(["payload", "report", "metrics", "workspace_release_status"], nil)
      |> put_in(["payload", "report", "metrics", "worker_ownership"], nil)

    Application.put_env(:arbor_commands, :coding_benchmark_legacy_test_reply, {:ok, result})

    assert {:ok, envelope} = LegacyAdapter.run(requests.legacy)
    assert envelope["observations"]["cleanup"]["status"] == "unobserved"
    assert envelope["worker_ownership"] == "unknown"
    refute envelope["observations"]["cleanup"]["status"] == "nil"
    refute envelope["worker_ownership"] == "nil"
  end

  defmodule ApprovalHistoryExecutor do
    @moduledoc false

    def run(_principal_id, _task, %{"task_id" => task_id}) do
      Arbor.Commands.CodingBenchmarkAdapterApprovalTest.emit_cycle(
        task_id,
        "irq_rework_cycle_aaaa",
        :rejected,
        rework: true
      )

      Arbor.Commands.CodingBenchmarkAdapterApprovalTest.emit_cycle(
        task_id,
        "irq_approve_cycle_bbbb",
        :approved
      )

      reply = Application.get_env(:arbor_commands, :coding_benchmark_legacy_test_reply)
      reply
    end
  end

  defmodule IsolatedApprovalExecutor do
    @moduledoc false

    def run(_principal_id, _task, %{"task_id" => task_id}) do
      other = task_id <> "-other"

      Arbor.Commands.CodingBenchmarkAdapterApprovalTest.emit_cycle(
        other,
        "irq_other_task_cccccc",
        :approved
      )

      Arbor.Commands.CodingBenchmarkAdapterApprovalTest.emit_cycle(
        task_id,
        "irq_this_task_dddddd",
        :approved
      )

      :ok =
        Arbor.Signals.emit(
          :interaction,
          :requested,
          %{
            request_id: "irq_clarify_eeeeeeee",
            kind: :clarification,
            agent_id: "agent_benchmark",
            user_id: "operator",
            urgency: :normal
          },
          correlation_id: task_id
        )

      Application.get_env(:arbor_commands, :coding_benchmark_legacy_test_reply)
    end
  end

  @doc false
  def emit_cycle(task_id, request_id, response, opts \\ []) do
    rework? = Keyword.get(opts, :rework, false)

    data = %{
      request_id: request_id,
      kind: :approval,
      agent_id: "agent_benchmark",
      user_id: "operator",
      urgency: :normal
    }

    :ok = Signals.emit(:interaction, :requested, data, correlation_id: task_id)
    :ok = Signals.emit(:interaction, :queued, data, correlation_id: task_id)

    resolved =
      if rework? do
        Map.merge(data, %{response: response, rework: true})
      else
        Map.put(data, :response, response)
      end

    :ok = Signals.emit(:interaction, :resolved, resolved, correlation_id: task_id)
    :ok
  end

  defp success_result do
    %{
      "result_type" => "coding_change",
      "payload" => %{
        "report" => %{
          "canonical_status" => "change_committed",
          "status" => "change_committed",
          "metrics" => %{
            "workspace_release_status" => "retained",
            "worker_ownership" => "owned",
            "total_rework_count" => 1,
            "validation_attempts" => 1
          }
        }
      },
      "raw" => %{}
    }
  end

  defp unique_requests! do
    requests = benchmark_requests!()
    seed = rem(System.unique_integer([:positive]), 2_147_483_648)

    %{
      requests
      | legacy: Map.put(requests.legacy, "seed", seed),
        pipeline: Map.put(requests.pipeline, "seed", seed)
    }
  end

  defp ensure_signals! do
    Application.ensure_all_started(:arbor_signals)

    for child <- [
          {Signals.Store, []},
          {Signals.TopicKeys, []},
          {Signals.Channels, []},
          {Signals.Bus, []},
          {Signals.Relay, []}
        ] do
      case Supervisor.start_child(Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          {mod, _} = child
          _ = Supervisor.delete_child(Signals.Supervisor, mod)
          _ = Supervisor.start_child(Signals.Supervisor, child)
          :ok

        {:error, _reason} ->
          :ok
      end
    end

    assert Signals.healthy?()
  end
end
