defmodule Arbor.Consensus.Evaluator.Deterministic do
  @moduledoc """
  Converts authoritative deterministic-validation evidence into a council vote.

  This evaluator does not execute commands. Proposal authors cannot select a
  project path, executable, environment, sandbox, or test path. Instead, the
  evaluator derives a closed `DeterministicRequest` from the proposal identity
  and perspective, then asks the operator-configured backend to resolve that
  request through an authorization-bound validation workflow.

  Missing backends, malformed evidence, timeouts, and backend failures reject
  the proposal. The default is therefore fail-closed.
  """

  @behaviour Arbor.Contracts.Consensus.Evaluator

  alias Arbor.Consensus.Config
  alias Arbor.Consensus.Evaluator.{DeterministicBackend, DeterministicRequest}
  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  @supported_perspectives [
    :mix_test,
    :mix_credo,
    :mix_compile,
    :mix_format_check,
    :mix_dialyzer
  ]

  @allowed_option_keys [:evaluator_id]
  @max_evaluator_id_bytes 256

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec name() :: atom()
  def name, do: :deterministic

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec perspectives() :: [atom()]
  def perspectives, do: @supported_perspectives

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec strategy() :: :deterministic
  def strategy, do: :deterministic

  @impl Arbor.Contracts.Consensus.Evaluator
  @spec evaluate(Proposal.t(), atom(), keyword()) :: {:ok, Evaluation.t()} | {:error, term()}
  def evaluate(%Proposal{} = proposal, perspective, opts \\ []) do
    evaluator_id = evaluator_id(opts, perspective)

    cond do
      perspective not in @supported_perspectives ->
        unsupported_perspective(proposal, perspective, evaluator_id)

      not valid_options?(opts) ->
        build_rejected_evaluation(
          proposal,
          perspective,
          evaluator_id,
          "deterministic_execution_controls_forbidden",
          0.95
        )

      true ->
        evaluate_request(proposal, perspective, evaluator_id)
    end
  end

  @doc """
  List supported perspectives for this evaluator.

  Deprecated: Use `perspectives/0` instead.
  """
  @spec supported_perspectives() :: [atom()]
  def supported_perspectives, do: @supported_perspectives

  defp evaluate_request(proposal, perspective, evaluator_id) do
    with {:ok, request} <-
           DeterministicRequest.new(%{
             proposal_id: proposal.id,
             perspective: perspective,
             timeout_ms: Config.deterministic_evaluator_timeout()
           }),
         {:ok, result} <- invoke_backend(Config.deterministic_evaluator_backend(), request) do
      build_evaluation_from_result(proposal, perspective, evaluator_id, result)
    else
      {:error, reason} ->
        build_rejected_evaluation(
          proposal,
          perspective,
          evaluator_id,
          public_failure_code(reason),
          0.5
        )
    end
  end

  defp invoke_backend(nil, _request), do: {:error, :deterministic_backend_unavailable}

  defp invoke_backend(backend, request) when is_atom(backend) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :evaluate, 1) do
      safely_invoke_backend(backend, request)
    else
      {:error, :invalid_deterministic_backend}
    end
  end

  defp invoke_backend(_backend, _request), do: {:error, :invalid_deterministic_backend}

  defp safely_invoke_backend(backend, request) do
    owner = self()
    result_ref = make_ref()
    deadline_ms = monotonic_ms() + request.timeout_ms

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        worker = self()
        _owner_guard = spawn_link(fn -> terminate_on_owner_exit(owner, worker) end)
        result = invoke_backend_once(backend, request)
        completed_ms = monotonic_ms()
        send(owner, {result_ref, completed_ms, result})
      end)

    await_backend_result(worker, monitor_ref, result_ref, deadline_ms)
  end

  defp terminate_on_owner_exit(owner, worker) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp invoke_backend_once(backend, request) do
    case backend.evaluate(request) do
      {:ok, result} ->
        normalize_backend_result(result, request)

      {:error, reason} ->
        if reason in DeterministicBackend.failure_reasons(),
          do: {:error, reason},
          else: {:error, :deterministic_backend_failed}

      _other ->
        {:error, :deterministic_backend_failed}
    end
  rescue
    _exception -> {:error, :deterministic_backend_failed}
  catch
    _kind, _reason -> {:error, :deterministic_backend_failed}
  end

  defp await_backend_result(worker, monitor_ref, result_ref, deadline_ms) do
    timeout_ms = max(deadline_ms - monotonic_ms(), 0)

    receive do
      {^result_ref, completed_ms, result} ->
        await_backend_down(worker, monitor_ref)

        if completed_ms <= deadline_ms do
          result
        else
          {:error, :deterministic_backend_timed_out}
        end

      {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
        {:error, :deterministic_backend_failed}
    after
      timeout_ms ->
        terminate_backend_worker(worker, monitor_ref, result_ref)
        {:error, :deterministic_backend_timed_out}
    end
  end

  defp await_backend_down(worker, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp terminate_backend_worker(worker, monitor_ref, result_ref) do
    Process.exit(worker, :kill)
    drain_backend_worker(worker, monitor_ref, result_ref)
  end

  defp drain_backend_worker(worker, monitor_ref, result_ref) do
    receive do
      {^result_ref, _completed_ms, _result} ->
        drain_backend_worker(worker, monitor_ref, result_ref)

      {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
        flush_backend_result(result_ref)
    end
  end

  defp flush_backend_result(result_ref) do
    receive do
      {^result_ref, _completed_ms, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp normalize_backend_result(
         %{status: status, code: code, duration_ms: duration_ms} = result,
         %DeterministicRequest{timeout_ms: timeout_ms}
       )
       when map_size(result) == 3 and not is_struct(result) do
    with true <- DeterministicBackend.valid_status_code?(status, code),
         true <- is_integer(duration_ms),
         true <- duration_ms >= 0 and duration_ms <= timeout_ms do
      {:ok, %{status: status, code: code, duration_ms: duration_ms}}
    else
      _other -> {:error, :invalid_deterministic_evidence}
    end
  end

  defp normalize_backend_result(_result, _request),
    do: {:error, :invalid_deterministic_evidence}

  defp build_evaluation_from_result(proposal, perspective, evaluator_id, result) do
    passed = result.status == :passed

    attrs = %{
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: if(passed, do: :approve, else: :reject),
      reasoning: result_reasoning(perspective, result),
      confidence: if(result.status == :blocked, do: 0.5, else: 0.95),
      concerns: result_concerns(perspective, result),
      recommendations: result_recommendations(perspective, result),
      risk_score: if(passed, do: 0.1, else: 0.9),
      benefit_score: if(passed, do: 0.9, else: 0.0)
    }

    seal_evaluation(attrs)
  end

  defp build_rejected_evaluation(proposal, perspective, evaluator_id, code, confidence) do
    attrs = %{
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :reject,
      reasoning: "#{perspective_name(perspective)} blocked (#{code})",
      confidence: confidence,
      concerns: ["Deterministic validation unavailable: #{code}"],
      recommendations: ["Provide authorization-bound deterministic validation evidence"],
      risk_score: 0.9,
      benefit_score: 0.0
    }

    seal_evaluation(attrs)
  end

  defp unsupported_perspective(proposal, perspective, evaluator_id) do
    supported = Enum.join(@supported_perspectives, ", ")

    seal_evaluation(%{
      proposal_id: proposal.id,
      evaluator_id: evaluator_id,
      perspective: perspective,
      vote: :abstain,
      reasoning: "Unsupported perspective: #{perspective}. Supported: #{supported}",
      confidence: 0.0,
      concerns: ["Unsupported evaluation perspective"],
      recommendations: ["Use a supported perspective or the RuleBased evaluator"],
      risk_score: 0.5,
      benefit_score: 0.0
    })
  end

  defp seal_evaluation(attrs) do
    case Evaluation.new(attrs) do
      {:ok, evaluation} -> {:ok, Evaluation.seal(evaluation)}
      {:error, _reason} = error -> error
    end
  end

  defp result_reasoning(perspective, result) do
    "#{perspective_name(perspective)} #{result.status} " <>
      "(#{result.duration_ms}ms, evidence code #{result.code})"
  end

  defp result_concerns(_perspective, %{status: :passed}), do: []

  defp result_concerns(perspective, result) do
    ["#{perspective_name(perspective)} #{result.status}: #{result.code}"]
  end

  defp result_recommendations(_perspective, %{status: :passed}), do: []

  defp result_recommendations(perspective, _result) do
    ["Resolve the #{perspective_name(perspective)} validation result before proceeding"]
  end

  defp perspective_name(:mix_test), do: "Mix test"
  defp perspective_name(:mix_credo), do: "Mix credo --strict"
  defp perspective_name(:mix_compile), do: "Mix compile --warnings-as-errors"
  defp perspective_name(:mix_format_check), do: "Mix format check"
  defp perspective_name(:mix_dialyzer), do: "Mix dialyzer"
  defp perspective_name(other), do: to_string(other)

  defp valid_options?(opts) do
    Keyword.keyword?(opts) and
      Keyword.keys(opts) -- @allowed_option_keys == [] and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
      valid_evaluator_id_option?(Keyword.get(opts, :evaluator_id))
  end

  defp evaluator_id(opts, perspective) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :evaluator_id) do
        value when is_binary(value) ->
          if safe_text?(value, @max_evaluator_id_bytes),
            do: value,
            else: generate_evaluator_id(perspective)

        _other ->
          generate_evaluator_id(perspective)
      end
    else
      generate_evaluator_id(perspective)
    end
  end

  defp evaluator_id(_opts, perspective), do: generate_evaluator_id(perspective)

  defp valid_evaluator_id_option?(nil), do: true

  defp valid_evaluator_id_option?(value) do
    safe_text?(value, @max_evaluator_id_bytes)
  end

  defp safe_text?(value, maximum) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum and
      String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, <<0>>) and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp public_failure_code(reason)
       when reason in [
              :deterministic_backend_unavailable,
              :deterministic_backend_unauthorized,
              :deterministic_backend_execution_failed,
              :deterministic_backend_timed_out,
              :deterministic_evidence_not_found,
              :invalid_deterministic_backend,
              :invalid_deterministic_evidence,
              :invalid_deterministic_request
            ],
       do: Atom.to_string(reason)

  defp public_failure_code(_reason), do: "deterministic_backend_failed"

  defp generate_evaluator_id(perspective) do
    perspective_name =
      if perspective in @supported_perspectives,
        do: Atom.to_string(perspective),
        else: "unsupported"

    "eval_det_#{perspective_name}_" <>
      Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
