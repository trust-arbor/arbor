defmodule Arbor.Consensus.ConsultFacadeTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus
  alias Arbor.Consensus.Evaluators.Consult
  alias Arbor.Consensus.TestHelpers.TestAdvisoryEvaluator

  @moduletag :fast

  defmodule RecordingLog do
    alias Arbor.Consensus.TestHelpers

    def new_run_id, do: "facade_run_#{System.unique_integer([:positive])}"

    def create_bound_run(question, perspectives, opts) do
      TestHelpers.notify_test({:create_run, question, perspectives, opts})
      {:ok, Keyword.get(opts, :run_id, "facade_run_1")}
    end

    def complete_run(run_id, results) do
      TestHelpers.notify_test({:complete_run, run_id, results})
      :ok
    end

    def finalize_run(run_id, outcome) do
      TestHelpers.notify_test({:finalize_run, run_id, outcome})
      {:ok, :transitioned}
    end
  end

  defmodule NilRunLog do
    def new_run_id, do: "nil_run_#{System.unique_integer([:positive])}"
    def create_bound_run(_question, _perspectives, _opts), do: nil
    def complete_run(_run_id, _results), do: :ok
    def finalize_run(_run_id, _outcome), do: {:ok, :transitioned}
  end

  defmodule RecordingSeatOwner do
    alias Arbor.Consensus.ConsultSeatOwner
    alias Arbor.Consensus.TestHelpers

    def start(caller, timeout) do
      TestHelpers.notify_test({:seat_owner_start, caller})
      ConsultSeatOwner.start(caller, timeout)
    end

    def supervisor(owner, timeout) do
      TestHelpers.notify_test({:seat_owner_supervisor, owner})
      ConsultSeatOwner.supervisor(owner, timeout)
    end

    def stop(owner) do
      TestHelpers.notify_test({:seat_owner_stop, owner})
      ConsultSeatOwner.stop(owner)
    end
  end

  test "consult/2 returns evaluations plus the ConsultationLog run id" do
    assert {:ok, %{evaluations: results, run_id: run_id} = result} =
             Consensus.consult("Should we extract a core?",
               evaluator: TestAdvisoryEvaluator,
               consultation_log: RecordingLog
             )

    assert is_binary(run_id)
    assert String.starts_with?(run_id, "facade_run_")
    assert length(results) == 2

    assert_received {:create_run, "Should we extract a core?", [:brainstorming, :design_review],
                     opts}

    assert Keyword.get(opts, :run_id) == run_id
    assert_received {:finalize_run, ^run_id, {:ok, ^result}}
    refute_received {:complete_run, _, _}
  end

  test "consult/2 preserves a nil ConsultationLog run id" do
    assert {:ok, %{evaluations: results, run_id: nil}} =
             Consensus.consult("Persistence unavailable",
               evaluator: TestAdvisoryEvaluator,
               consultation_log: NilRunLog
             )

    assert length(results) == 2
  end

  test "consult/2 honors the injected seat-owner collaborator across the whole lifecycle" do
    caller = self()

    assert {:ok, %{evaluations: results}} =
             Consensus.consult("Injected seat owner",
               evaluator: TestAdvisoryEvaluator,
               consultation_log: NilRunLog,
               seat_owner: RecordingSeatOwner
             )

    assert length(results) == 2
    assert_received {:seat_owner_start, ^caller}
    assert_received {:seat_owner_supervisor, owner}
    assert is_pid(owner)
    assert_received {:seat_owner_stop, ^owner}
  end

  defmodule HangingStopSeatOwner do
    def start(caller, timeout) do
      result = Arbor.Consensus.ConsultSeatOwner.start(caller, timeout)

      case result do
        {:ok, pid} -> send(caller, {:hanging_stop_owner, pid})
        _ -> :ok
      end

      result
    end

    def supervisor(owner, timeout), do: Arbor.Consensus.ConsultSeatOwner.supervisor(owner, timeout)
    def stop(_owner), do: Process.sleep(:infinity)
  end

  test "consult/2 returns within the wall-clock bound when injected stop/1 sleeps indefinitely" do
    started = System.system_time(:millisecond)

    assert {:ok, %{evaluations: results}} =
             Consensus.consult("Hanging stop must not block consult",
               evaluator: TestAdvisoryEvaluator,
               consultation_log: NilRunLog,
               seat_owner: HangingStopSeatOwner
             )

    assert length(results) == 2
    assert_received {:hanging_stop_owner, owner}
    refute Process.alive?(owner)
    assert System.system_time(:millisecond) - started < 6_500
  end

  test "legacy ask/3 still returns only evaluations" do
    assert {:ok, results} = Consult.ask(TestAdvisoryEvaluator, "Legacy shape")
    assert is_list(results)
    refute match?({:ok, %{evaluations: _, run_id: _}}, {:ok, results})
  end

  test "consult/2 rejects each invalid option without raising" do
    assert {:error, {:invalid_option, :timeout}} = Consensus.consult("q", timeout: -1)
    assert {:error, {:invalid_option, :timeout}} = Consensus.consult("q", timeout: 0)
    assert {:error, {:invalid_option, :timeout}} = Consensus.consult("q", timeout: "fast")

    assert {:error, {:invalid_option, :deadline_unix_ms}} =
             Consensus.consult("q", deadline_unix_ms: -1)

    assert {:error, {:invalid_option, :deadline_unix_ms}} =
             Consensus.consult("q", deadline_unix_ms: 0)

    assert {:error, {:invalid_option, :deadline_unix_ms}} =
             Consensus.consult("q", deadline_unix_ms: "soon")

    assert {:error, {:invalid_option, :evaluator}} = Consensus.consult("q", evaluator: 123)
    assert {:error, {:invalid_option, :evaluator}} = Consensus.consult("q", evaluator: "mod")

    assert {:error, {:invalid_option, :evaluator}} =
             Consensus.consult("q", evaluator: :not_a_module)

    assert {:error, {:invalid_option, :evaluator}} = Consensus.consult("q", evaluator: String)

    assert {:error, {:invalid_option, :evaluator}} =
             Consensus.consult("q", evaluator: Arbor.Consensus)

    assert {:error, {:invalid_option, :finalizer_grace_ms}} =
             Consensus.consult("q", finalizer_grace_ms: -1)

    assert {:error, {:invalid_option, :consultation_log}} =
             Consensus.consult("q", consultation_log: 123)

    assert {:error, {:invalid_option, :consultation_log}} =
             Consensus.consult("q", consultation_log: nil)

    assert {:error, {:invalid_option, :consultation_log}} =
             Consensus.consult("q", consultation_log: :not_a_module)

    assert {:error, {:invalid_option, :consultation_log}} =
             Consensus.consult("q", consultation_log: String)

    assert {:error, {:invalid_option, :consultation_log}} =
             Consensus.consult("q", consultation_log: Arbor.Consensus)

    assert {:error, {:invalid_option, :finalizer_grace_ms}} =
             Consensus.consult("q", finalizer_grace_ms: Consensus.max_finalizer_grace_ms() + 1)

    assert {:error, {:invalid_option, :finalizer_supervisor}} =
             Consensus.consult("q", finalizer_supervisor: nil)

    assert {:error, {:invalid_option, :finalizer_supervisor}} =
             Consensus.consult("q", finalizer_supervisor: 123)

    assert {:error, {:invalid_option, :persist_timeout_ms}} =
             Consensus.consult("q", persist_timeout_ms: 0)

    assert {:error, {:invalid_option, :persist_timeout_ms}} =
             Consensus.consult("q", persist_timeout_ms: -1)

    assert {:error, {:invalid_option, :persist_timeout_ms}} =
             Consensus.consult("q", persist_timeout_ms: "fast")

    assert {:error, {:invalid_option, :persist_timeout_ms}} =
             Consensus.consult("q", persist_timeout_ms: Consensus.max_persist_timeout_ms() + 1)

    assert {:error, {:invalid_option, :seat_owner}} =
             Consensus.consult("q", seat_owner: nil)

    assert {:error, {:invalid_option, :seat_owner}} =
             Consensus.consult("q", seat_owner: String)

    assert {:error, {:invalid_option, :context}} = Consensus.consult("q", context: "not a map")
    assert {:error, {:invalid_option, :research}} = Consensus.consult("q", research: "yes")
    assert {:error, {:invalid_option, :ai_module}} = Consensus.consult("q", ai_module: 1)

    assert {:error, {:invalid_option, :provider_model}} =
             Consensus.consult("q", provider_model: 1)

    assert {:error, {:invalid_option, :now_ms}} = Consensus.consult("q", now_ms: -1)
    assert {:error, {:invalid_option, :now_ms}} = Consensus.consult("q", now_ms: 1_000)
    assert {:error, {:invalid_option, :bogus}} = Consensus.consult("q", bogus: true)
    assert {:error, {:invalid_option, :opts}} = Consensus.consult("q", [{"timeout", 100}])
  end

  test "consult/2 accepts a behaviour-conforming evaluator without strategy/0" do
    defmodule PartialEvaluator do
      def name, do: :partial
      def perspectives, do: [:security]
      def evaluate(_proposal, _perspective, _opts), do: {:error, :unused}
    end

    assert {:ok, %{evaluations: [{:security, {:error, :unused}}]}} =
             Consensus.consult("q",
               evaluator: PartialEvaluator,
               consultation_log: NilRunLog
             )
  end
end
