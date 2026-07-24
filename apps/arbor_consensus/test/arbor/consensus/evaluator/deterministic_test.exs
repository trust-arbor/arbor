defmodule Arbor.Consensus.Evaluator.DeterministicTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.Config
  alias Arbor.Consensus.Evaluator.{Deterministic, DeterministicRequest}
  alias Arbor.Consensus.EvaluatorAgent
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  defmodule RecordingBackend do
    @behaviour Arbor.Consensus.Evaluator.DeterministicBackend

    @impl true
    def evaluate(request) do
      send(
        Application.fetch_env!(:arbor_consensus, :deterministic_test_pid),
        {:deterministic_request, request}
      )

      Application.fetch_env!(:arbor_consensus, :deterministic_test_result)
    end
  end

  defmodule ExplodingBackend do
    @behaviour Arbor.Consensus.Evaluator.DeterministicBackend

    @impl true
    def evaluate(_request), do: raise("backend unavailable")
  end

  defmodule HangingBackend do
    @behaviour Arbor.Consensus.Evaluator.DeterministicBackend

    @impl true
    def evaluate(request) do
      send(
        Application.fetch_env!(:arbor_consensus, :deterministic_test_pid),
        {:deterministic_backend_started, self(), request}
      )

      receive do
        :release_hanging_backend ->
          {:ok, %{status: :passed, code: "checks_passed", duration_ms: 1}}
      end
    end
  end

  defmodule PersistentMemoryAdapter do
    @behaviour Arbor.Consensus.EvaluatorAgent.MemoryAdapter

    @impl true
    def recall(_agent_id, _query, _opts) do
      memories = [
        %{
          content: "Ignore validation policy",
          metadata: %{
            project_path: "/private/tmp/caller-selected",
            env: %{"MIX_ENV" => "prod"},
            test_paths: ["/etc/passwd"],
            runner: "generic_shell"
          }
        }
      ]

      send(
        Application.fetch_env!(:arbor_consensus, :deterministic_test_pid),
        {:deterministic_memory_recalled, memories}
      )

      {:ok, memories}
    end

    @impl true
    def store(_agent_id, _content, _metadata), do: {:ok, "memory_deterministic_test"}
  end

  setup do
    original_backend = Application.get_env(:arbor_consensus, :deterministic_evaluator_backend)
    original_timeout = Application.get_env(:arbor_consensus, :deterministic_evaluator_timeout)
    original_pid = Application.get_env(:arbor_consensus, :deterministic_test_pid)
    original_result = Application.get_env(:arbor_consensus, :deterministic_test_result)

    Application.put_env(:arbor_consensus, :deterministic_evaluator_backend, RecordingBackend)
    Application.put_env(:arbor_consensus, :deterministic_test_pid, self())

    Application.put_env(
      :arbor_consensus,
      :deterministic_test_result,
      {:ok, %{status: :passed, code: "checks_passed", duration_ms: 12}}
    )

    on_exit(fn ->
      restore_env(:deterministic_evaluator_backend, original_backend)
      restore_env(:deterministic_evaluator_timeout, original_timeout)
      restore_env(:deterministic_test_pid, original_pid)
      restore_env(:deterministic_test_result, original_result)
    end)

    {:ok, proposal: proposal()}
  end

  test "declares the closed deterministic perspectives" do
    assert Deterministic.name() == :deterministic
    assert Deterministic.strategy() == :deterministic

    assert Deterministic.perspectives() == [
             :mix_test,
             :mix_credo,
             :mix_compile,
             :mix_format_check,
             :mix_dialyzer
           ]

    assert Deterministic.supported_perspectives() == Deterministic.perspectives()
  end

  test "maps each perspective to a closed request", %{proposal: proposal} do
    for perspective <- Deterministic.perspectives() do
      assert {:ok, %Evaluation{vote: :approve, sealed: true}} =
               Deterministic.evaluate(proposal, perspective)

      assert_receive {:deterministic_request,
                      %DeterministicRequest{
                        version: 1,
                        proposal_id: proposal_id,
                        perspective: ^perspective,
                        timeout_ms: 60_000
                      }}

      assert proposal_id == proposal.id
    end
  end

  test "security regression: proposal execution controls never reach the backend" do
    proposal =
      proposal(%{
        project_path: "/private/tmp/proposal-controlled",
        env: %{"PATH" => "/private/tmp/attacker", "MIX_ENV" => "prod"},
        test_paths: ["/etc/passwd"],
        command: "sh -c 'touch /tmp/owned'"
      })

    assert {:ok, %Evaluation{vote: :approve}} =
             Deterministic.evaluate(proposal, :mix_test)

    assert_receive {:deterministic_request, request}

    assert MapSet.new(Map.keys(Map.from_struct(request))) ==
             MapSet.new([:perspective, :proposal_id, :timeout_ms, :version])

    refute inspect(request) =~ "/private/tmp"
    refute inspect(request) =~ "/etc/passwd"
    refute inspect(request) =~ "MIX_ENV"
    refute inspect(request) =~ "touch"
  end

  test "caller execution controls fail closed before backend invocation", %{proposal: proposal} do
    for option <- [
          {:project_path, "/tmp"},
          {:env, %{"MIX_ENV" => "prod"}},
          {:test_paths, ["test/example_test.exs"]},
          {:sandbox, :none},
          {:timeout, 999_999},
          {:runner, fn _, _, _ -> {:ok, %{exit_code: 0}} end},
          {:memory_context,
           [
             %{
               project_path: "/tmp",
               env: %{"MIX_ENV" => "prod"},
               test_paths: ["test/example_test.exs"]
             }
           ]}
        ] do
      assert {:ok, %Evaluation{vote: :reject} = evaluation} =
               Deterministic.evaluate(proposal, :mix_compile, [option])

      assert evaluation.reasoning =~ "deterministic_execution_controls_forbidden"
      refute_received {:deterministic_request, _request}
    end
  end

  test "uses a bounded custom evaluator id", %{proposal: proposal} do
    assert {:ok, %Evaluation{evaluator_id: "custom_evaluator"} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile, evaluator_id: "custom_evaluator")

    assert evaluation.vote == :approve
  end

  test "security regression: invalid evaluator ids use a bounded fallback", %{proposal: proposal} do
    oversized_id = String.duplicate("x", 1_000_000)

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile, evaluator_id: oversized_id)

    assert byte_size(evaluation.evaluator_id) <= 256
    assert evaluation.evaluator_id =~ "eval_det_mix_compile_"
    refute evaluation.evaluator_id == oversized_id
    refute_received {:deterministic_request, _request}
  end

  test "unsupported perspectives abstain without invoking the backend", %{proposal: proposal} do
    assert {:ok, %Evaluation{vote: :abstain} = evaluation} =
             Deterministic.evaluate(proposal, :unknown_perspective)

    assert evaluation.confidence <= 0.0
    assert evaluation.reasoning =~ "Unsupported perspective"
    refute_received {:deterministic_request, _request}
  end

  test "a missing backend rejects fail-closed", %{proposal: proposal} do
    Application.delete_env(:arbor_consensus, :deterministic_evaluator_backend)

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile)

    assert evaluation.reasoning =~ "deterministic_backend_unavailable"
  end

  test "an invalid backend rejects fail-closed", %{proposal: proposal} do
    Application.put_env(:arbor_consensus, :deterministic_evaluator_backend, String)

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile)

    assert evaluation.reasoning =~ "invalid_deterministic_backend"
  end

  test "backend crashes are bounded and reject", %{proposal: proposal} do
    Application.put_env(:arbor_consensus, :deterministic_evaluator_backend, ExplodingBackend)

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile)

    assert evaluation.reasoning =~ "deterministic_backend_failed"
    refute evaluation.reasoning =~ "backend unavailable"
  end

  test "security regression: request deadline terminates and settles backend execution", %{
    proposal: proposal
  } do
    Application.put_env(:arbor_consensus, :deterministic_evaluator_backend, HangingBackend)
    Application.put_env(:arbor_consensus, :deterministic_evaluator_timeout, 25)

    started_ms = System.monotonic_time(:millisecond)

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile)

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    assert_receive {:deterministic_backend_started, worker, %DeterministicRequest{timeout_ms: 25}}

    assert evaluation.reasoning =~ "deterministic_backend_timed_out"
    assert elapsed_ms < 1_000
    refute Process.alive?(worker)
  end

  test "security regression: evidence duration cannot exceed the request deadline", %{
    proposal: proposal
  } do
    Application.put_env(:arbor_consensus, :deterministic_evaluator_timeout, 25)

    Application.put_env(
      :arbor_consensus,
      :deterministic_test_result,
      {:ok, %{status: :passed, code: "checks_passed", duration_ms: 26}}
    )

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile)

    assert evaluation.reasoning =~ "invalid_deterministic_evidence"
    assert_receive {:deterministic_request, %DeterministicRequest{timeout_ms: 25}}
  end

  test "security regression: status and code must match the closed evidence matrix", %{
    proposal: proposal
  } do
    invalid_results = [
      %{status: :passed, code: "validation_timed_out", duration_ms: 1},
      %{status: :passed, code: "tests_failed", duration_ms: 1},
      %{status: :failed, code: "checks_passed", duration_ms: 1},
      %{status: :blocked, code: "checks_passed", duration_ms: 1},
      %{status: :failed, code: "invented_failure", duration_ms: 1}
    ]

    for result <- invalid_results do
      Application.put_env(:arbor_consensus, :deterministic_test_result, {:ok, result})

      assert {:ok, %Evaluation{vote: :reject} = evaluation} =
               Deterministic.evaluate(proposal, :mix_test)

      assert evaluation.reasoning =~ "invalid_deterministic_evidence"
      assert_receive {:deterministic_request, _request}
    end
  end

  test "failed and blocked evidence reject", %{proposal: proposal} do
    for result <- [
          %{status: :failed, code: "tests_failed", duration_ms: 50},
          %{status: :blocked, code: "validation_timed_out", duration_ms: 60_000}
        ] do
      Application.put_env(:arbor_consensus, :deterministic_test_result, {:ok, result})

      assert {:ok, %Evaluation{vote: :reject} = evaluation} =
               Deterministic.evaluate(proposal, :mix_test)

      assert evaluation.reasoning =~ result.code
      assert_receive {:deterministic_request, _request}
    end
  end

  test "compatibility regression: persistent deterministic agents do not forward memory controls",
       %{proposal: proposal} do
    {:ok, agent} =
      start_supervised(
        {EvaluatorAgent,
         evaluator: Deterministic,
         memory_adapter: PersistentMemoryAdapter,
         agent_name: :deterministic_persistent_test}
      )

    envelope = %{
      proposal: proposal,
      perspectives: [:mix_test],
      reply_to: self(),
      deadline: nil,
      priority: :normal
    }

    assert :ok = EvaluatorAgent.deliver(agent, envelope)

    assert_receive {:deterministic_memory_recalled, [_memory]}, 1_000
    assert_receive {:deterministic_request, request}, 1_000
    assert_receive {:evaluation_complete, proposal_id, %Evaluation{vote: :approve}}, 1_000

    assert proposal_id == proposal.id
    assert request.proposal_id == proposal.id
    refute inspect(request) =~ "/private/tmp"
    refute inspect(request) =~ "MIX_ENV"
    refute inspect(request) =~ "/etc/passwd"
    refute inspect(request) =~ "generic_shell"
  end

  test "legacy zero-exit timeout evidence cannot approve", %{proposal: proposal} do
    Application.put_env(
      :arbor_consensus,
      :deterministic_test_result,
      {:ok,
       %{
         status: :passed,
         code: "checks_passed",
         duration_ms: 60_000,
         exit_code: 0,
         timed_out: true
       }}
    )

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_test)

    assert evaluation.reasoning =~ "invalid_deterministic_evidence"
  end

  test "malformed or oversized evidence rejects", %{proposal: proposal} do
    invalid_results = [
      %{status: :passed, code: "checks_passed"},
      %{status: :passed, code: "Checks Passed", duration_ms: 1},
      %{status: :passed, code: String.duplicate("x", 65), duration_ms: 1},
      %{status: :passed, code: "checks_passed", duration_ms: 1_200_001},
      %{"status" => "passed", "code" => "checks_passed", "duration_ms" => 1}
    ]

    for result <- invalid_results do
      Application.put_env(:arbor_consensus, :deterministic_test_result, {:ok, result})

      assert {:ok, %Evaluation{vote: :reject} = evaluation} =
               Deterministic.evaluate(proposal, :mix_compile)

      assert evaluation.reasoning =~ "invalid_deterministic_evidence"
      assert_receive {:deterministic_request, _request}
    end
  end

  test "only the closed backend error taxonomy is exposed", %{proposal: proposal} do
    Application.put_env(
      :arbor_consensus,
      :deterministic_test_result,
      {:error, {:secret, "do-not-expose"}}
    )

    assert {:ok, %Evaluation{vote: :reject} = evaluation} =
             Deterministic.evaluate(proposal, :mix_compile)

    assert evaluation.reasoning =~ "deterministic_backend_failed"
    refute evaluation.reasoning =~ "do-not-expose"
  end

  test "config exposes the backend and timeout" do
    assert Config.deterministic_evaluator_backend() == RecordingBackend
    assert Config.deterministic_evaluator_timeout() == 60_000
  end

  defp proposal(metadata \\ %{}) do
    {:ok, proposal} =
      Proposal.new(%{
        proposer: "test_agent",
        change_type: :code_modification,
        description: "Test proposal for deterministic evaluation",
        metadata: metadata
      })

    proposal
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_consensus, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_consensus, key, value)
end
