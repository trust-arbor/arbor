defmodule Arbor.Actions.Coding.DesignCouncilReview do
  @moduledoc """
  Consult the advisory council over an admitted coding design.

  Pipeline-internal syscall. The design text is loaded from the archived
  artifact by digest — worker-supplied `design` context is ignored. Consult
  goes through the public `Arbor.Consensus` facade (injectable for tests).
  Failure, timeout, or a missing ConsultationLog run id is an explicit error,
  never an approval.
  """

  use Jido.Action,
    name: "coding_design_council_review",
    description: "Consult the advisory council on the archived coding design",
    category: "coding",
    tags: ["coding", "design_checkpoint", "council", "pipeline_internal"],
    schema: [
      work_packet: [type: :map, required: true, doc: "Canonical CodingPlan v2 work packet"],
      packet_digest: [type: :string, required: false, doc: "Exact sha256: work-packet digest"],
      work_packet_digest: [type: :string, required: false, doc: "Alias for packet_digest"],
      task_id: [type: :string, required: true, doc: "Coding task identity"],
      task: [type: :string, required: true, doc: "Exact nonempty reviewed coding task text"],
      design_artifact: [type: :map, required: true, doc: "Closed design artifact descriptor"],
      design_digest: [type: :string, required: true, doc: "Exact sha256: design digest"],
      design_attempt: [type: :integer, required: true, doc: "One-based design attempt"],
      run_deadline_unix_ms: [
        type: :integer,
        required: true,
        doc: "Executor-owned absolute run deadline in Unix milliseconds"
      ],
      timeout: [
        type: :integer,
        required: false,
        doc: "Static consultation-wide timeout in milliseconds"
      ],
      veto_perspectives: [
        type: {:list, :string},
        required: false,
        doc: "Perspectives whose reject forces rework"
      ],
      reject_threshold: [
        type: :integer,
        required: false,
        doc: "Rework when reject count is at least this many"
      ],
      min_responders: [
        type: :integer,
        required: false,
        doc: "Rework when fewer than this many seats voted approve or reject"
      ]
    ]

  require Logger

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Actions.Coding.DesignCouncilCore

  def taint_roles do
    %{
      work_packet: :data,
      packet_digest: :control,
      work_packet_digest: :control,
      task_id: :control,
      task: :data,
      design_artifact: :control,
      design_digest: :control,
      design_attempt: :control,
      run_deadline_unix_ms: :control,
      timeout: :data,
      veto_perspectives: :control,
      reject_threshold: :control,
      min_responders: :control
    }
  end

  def effect_class, do: :network_egress
  def egress_tier(_params, _context), do: :external_provider
  def egress_destination(_params, _context), do: "advisory-design-council"

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, %{packet: packet}} <- DesignCheckpoint.bind_work_packet(params, context),
         {:ok, task_id} <- required_task_id(params, context),
         {:ok, task} <- required_task(params, context),
         {:ok, design_attempt} <- required_attempt(params, context),
         {:ok, design} <- load_admitted_design(params, context, task_id, design_attempt),
         {:ok, question} <- DesignCouncilCore.build_question(packet, task, design),
         {:ok, deadline} <- consult_deadline(params, context),
         {:ok, %{evaluations: evaluations, run_id: run_id}} <-
           consult(question, deadline, context),
         {:ok, run_id} <- require_consultation_run_id(run_id),
         {:ok, evaluations} <- admit_design_review_evaluations(evaluations),
         {:ok, state} <-
           DesignCouncilCore.new(%{
             "evaluations" => evaluations,
             "veto_perspectives" => value(params, context, :veto_perspectives),
             "reject_threshold" => value(params, context, :reject_threshold),
             "min_responders" => value(params, context, :min_responders)
           }),
         {:ok, decided} <- DesignCouncilCore.decide(state) do
      {:ok, result(decided, run_id)}
    else
      {:error, reason} -> {:error, project_error(reason)}
    end
  end

  def run(_params, _context), do: {:error, :invalid_design_council_input}

  defp result(decided, run_id) do
    %{
      "checkpoint_outcome" => decided["checkpoint_outcome"],
      "note" => decided["note"],
      "dispersion" => decided["dispersion"],
      "design_council_run_id" => run_id,
      "evidence" => %{"design_council_run_id" => run_id}
    }
  end

  defp load_admitted_design(params, context, task_id, design_attempt) do
    with {:ok, descriptor} <- descriptor_input(params, context),
         {:ok, design_digest} <- design_digest_input(params, context) do
      binding = %{task_id: task_id, design_attempt: design_attempt}
      DesignCheckpoint.verify_design_artifact(context, binding, descriptor, design_digest)
    end
  end

  defp consult(question, deadline, context) do
    consensus = consensus_boundary(context)
    opts = [deadline_unix_ms: deadline, context: %{"evaluation_protocol" => "design_review"}]

    case call_consult(consensus, question, opts) do
      {:ok, %{evaluations: evaluations, run_id: run_id}} when is_list(evaluations) ->
        {:ok, %{evaluations: evaluations, run_id: run_id}}

      {:error, :timeout} ->
        {:error, :design_council_timeout}

      {:error, reason} ->
        {:error, {:design_council_consult_failed, reason}}

      _other ->
        {:error, :design_council_consult_failed}
    end
  end

  defp admit_design_review_evaluations(evaluations) when is_list(evaluations) do
    {:ok, Enum.map(evaluations, &admit_design_review_evaluation/1)}
  end

  defp admit_design_review_evaluations(_evaluations),
    do: {:error, :invalid_design_council_evaluations}

  defp admit_design_review_evaluation({perspective, {:error, _} = error}),
    do: {perspective, error}

  defp admit_design_review_evaluation({perspective, evaluation}) when is_map(evaluation) do
    case design_review_verdict(evaluation) do
      {:ok, vote, concerns} ->
        {perspective, put_admitted_verdict(evaluation, vote, concerns)}

      {:seat_error, reason} ->
        # A well-formed verdict with a malformed payload is a seat ERROR,
        # not a rework vote: it counts in dispersion.error and is never a
        # responder or veto. Out-of-protocol VERDICTS still convert to
        # rework in the `{:error, problem}` clause below.
        {perspective, {:error, reason}}

      {:error, problem} ->
        {perspective,
         %{
           perspective: perspective,
           vote: :rework,
           concerns: [problem],
           reasoning: problem
         }}
    end
  end

  defp admit_design_review_evaluation({perspective, _other}) do
    problem = "malformed design-review evaluation"

    {perspective,
     %{
       perspective: perspective,
       vote: :rework,
       concerns: [problem],
       reasoning: problem
     }}
  end

  defp admit_design_review_evaluation(_other) do
    problem = "malformed design-review evaluation"

    {nil,
     %{
       vote: :rework,
       concerns: [problem],
       reasoning: problem
     }}
  end

  defp design_review_verdict(evaluation) when is_map(evaluation) do
    vote = Map.get(evaluation, :vote) || Map.get(evaluation, "vote")

    case normalize_admitted_verdict(vote) do
      {:ok, verdict} ->
        case admitted_concerns(evaluation) do
          {:ok, concerns} -> {:ok, verdict, concerns}
          :error -> {:seat_error, :malformed_evaluation}
        end

      {:out_of_protocol, vote} ->
        {:error,
         "out-of-protocol design-review verdict #{inspect(vote)}: only approve|rework are admitted"}

      :missing ->
        parse_verdict_from_reasoning(evaluation)

      :error ->
        {:error, "malformed design-review verdict"}
    end
  end

  # VOTE TRANSLATION — single source of truth for the three layers:
  #   1. design-review protocol verdicts (seat output): approve | rework
  #   2. AdvisoryLLM `Evaluation.vote` internal encoding: rework travels as
  #      `:reject` (the evaluator's generic vote vocabulary)
  #   3. admitted verdict (this action → DesignCouncilCore): approve | rework
  # Only approve and rework are admitted; reject is accepted solely as the
  # AdvisoryLLM internal encoding of rework. Everything else — abstain,
  # error, unknown tokens — is OUT OF PROTOCOL and converts to rework with
  # the problem recorded as the concern (never approve).
  defp normalize_admitted_verdict(vote) when vote in [:approve, "approve"], do: {:ok, :approve}
  defp normalize_admitted_verdict(vote) when vote in [:rework, "rework"], do: {:ok, :rework}
  defp normalize_admitted_verdict(vote) when vote in [:reject, "reject"], do: {:ok, :rework}

  defp normalize_admitted_verdict(vote) when vote in [:abstain, "abstain", :error, "error"],
    do: {:out_of_protocol, vote}

  defp normalize_admitted_verdict(nil), do: :missing
  defp normalize_admitted_verdict(_vote), do: :error

  defp parse_verdict_from_reasoning(evaluation) do
    reasoning = Map.get(evaluation, :reasoning) || Map.get(evaluation, "reasoning")

    case decode_reasoning_payload(reasoning) do
      {:ok, json} when is_map(json) ->
        case normalize_admitted_verdict(Map.get(json, "verdict") || Map.get(json, :verdict)) do
          {:ok, verdict} ->
            case admitted_concerns(json) do
              {:ok, concerns} -> {:ok, verdict, concerns}
              :error -> {:seat_error, :malformed_evaluation}
            end

          _other ->
            {:error, "malformed design-review verdict: missing or invalid verdict"}
        end

      _other ->
        {:error, "malformed design-review verdict: missing or invalid verdict"}
    end
  end

  defp decode_reasoning_payload(text) when is_binary(text), do: Jason.decode(text)
  defp decode_reasoning_payload(map) when is_map(map), do: {:ok, map}
  defp decode_reasoning_payload(_other), do: :error

  defp admitted_concerns(source) when is_map(source) do
    cond do
      Map.has_key?(source, :concerns) ->
        normalize_admitted_concern_list(Map.get(source, :concerns))

      Map.has_key?(source, "concerns") ->
        normalize_admitted_concern_list(Map.get(source, "concerns"))

      true ->
        {:ok, []}
    end
  end

  defp normalize_admitted_concern_list(nil), do: {:ok, []}

  defp normalize_admitted_concern_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn item, {:ok, acc} ->
      if is_binary(item) and String.valid?(item) do
        {:cont, {:ok, [String.trim(item) | acc]}}
      else
        {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(Enum.reject(acc, &(&1 == "")))}
      :error -> :error
    end
  end

  defp normalize_admitted_concern_list(_values), do: :error

  defp put_admitted_verdict(evaluation, vote, concerns) when is_map(evaluation) do
    evaluation
    |> Map.put(:vote, vote)
    |> Map.put("vote", vote)
    |> Map.put(:concerns, concerns)
    |> Map.put("concerns", concerns)
  end

  defp require_consultation_run_id(run_id) when is_binary(run_id) do
    case DesignCheckpoint.validate_identifier(run_id, :design_council_run_id) do
      {:ok, ^run_id} -> {:ok, run_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_consultation_run_id(_run_id), do: {:error, :design_council_run_id_required}

  defp consensus_boundary(context) when is_map(context) do
    Map.get(context, :consensus) || Map.get(context, "consensus") || Arbor.Consensus
  end

  defp call_consult(target, question, opts) do
    invoke_consult(target, question, opts)
  rescue
    UndefinedFunctionError -> {:error, :design_council_consensus_unavailable}
    _ -> {:error, :design_council_consult_failed}
  catch
    :exit, _ -> {:error, :design_council_consensus_unavailable}
    _, _ -> {:error, :design_council_consult_failed}
  end

  defp invoke_consult(module, question, opts) when is_atom(module) do
    apply(module, :consult, [question, opts])
  end

  defp invoke_consult(fun, question, opts) when is_function(fun, 2), do: fun.(question, opts)
  defp invoke_consult(_other, _question, _opts), do: {:error, :invalid_design_council_consensus}

  defp consult_deadline(params, context) do
    now_ms = now_ms(context)

    with {:ok, deadline} <- run_deadline_unix_ms(params, context),
         :ok <- future_deadline(deadline, now_ms) do
      case value(params, context, :timeout) do
        timeout when is_integer(timeout) and timeout > 0 ->
          {:ok, min(deadline, now_ms + timeout)}

        nil ->
          {:ok, deadline}

        _ ->
          {:error, :invalid_design_council_timeout}
      end
    end
  end

  defp now_ms(context) do
    case Map.get(context, :now_ms) || Map.get(context, "now_ms") do
      now when is_integer(now) and now > 0 -> now
      _ -> System.system_time(:millisecond)
    end
  end

  defp run_deadline_unix_ms(params, context) do
    case deadline_input(context) do
      :missing -> params |> deadline_input() |> validate_run_deadline()
      context_input -> validate_run_deadline(context_input)
    end
  end

  defp deadline_input(source) do
    case {
      Map.fetch(source, :run_deadline_unix_ms),
      Map.fetch(source, "run_deadline_unix_ms")
    } do
      {:error, :error} -> :missing
      {{:ok, deadline}, :error} -> {:ok, deadline}
      {:error, {:ok, deadline}} -> {:ok, deadline}
      {{:ok, deadline}, {:ok, deadline}} -> {:ok, deadline}
      {{:ok, _atom}, {:ok, _string}} -> :conflict
    end
  end

  defp validate_run_deadline(:missing), do: {:error, :design_council_deadline_required}
  defp validate_run_deadline(:conflict), do: {:error, :invalid_design_council_deadline}

  defp validate_run_deadline({:ok, deadline}) when is_integer(deadline) and deadline > 0,
    do: {:ok, deadline}

  defp validate_run_deadline({:ok, _deadline}), do: {:error, :invalid_design_council_deadline}

  defp future_deadline(deadline, now_ms) when deadline > now_ms, do: :ok
  defp future_deadline(_deadline, _now_ms), do: {:error, :design_council_deadline_elapsed}

  defp descriptor_input(params, context) do
    case value(params, context, :design_artifact) do
      descriptor when is_map(descriptor) -> {:ok, descriptor}
      _ -> {:error, :design_artifact_descriptor_required}
    end
  end

  defp design_digest_input(params, context) do
    case value(params, context, :design_digest) do
      digest when is_binary(digest) -> {:ok, digest}
      _ -> {:error, :design_digest_mismatch}
    end
  end

  defp required_task_id(params, context) do
    case value(params, context, :task_id) || Map.get(context, "session.task_id") do
      task_id when is_binary(task_id) and task_id != "" -> {:ok, task_id}
      _ -> {:error, {:design_checkpoint_identifier_required, "task_id"}}
    end
  end

  defp required_task(params, context) do
    case value(params, context, :task) do
      task when is_binary(task) and byte_size(task) > 0 -> {:ok, task}
      _ -> {:error, :design_checkpoint_task_required}
    end
  end

  defp required_attempt(params, context) do
    case value(params, context, :design_attempt) do
      value when is_integer(value) and value > 0 and value <= 1_000_000 -> {:ok, value}
      _ -> {:error, :design_checkpoint_attempt_invalid}
    end
  end

  defp project_error(:timeout), do: :design_council_timeout
  defp project_error(:design_council_timeout), do: :design_council_timeout
  defp project_error(:design_council_deadline_elapsed), do: :design_council_deadline_elapsed
  defp project_error(:design_council_run_id_required), do: :design_council_run_id_required

  defp project_error({:design_council_consult_failed, reason}) do
    # Preserve the inner consult failure in the log before collapsing to the
    # action-boundary atom, so operators can tell timeout vs invalid-option
    # vs create-failure apart.
    Logger.warning(
      "design_council_review: consult failed reason=#{inspect(reason, limit: 10, printable_limit: 300)}"
    )

    :design_council_consult_failed
  end

  defp project_error(reason), do: reason

  defp value(primary, secondary, key) do
    Map.get(primary, key) || Map.get(primary, Atom.to_string(key)) || Map.get(secondary, key) ||
      Map.get(secondary, Atom.to_string(key))
  end
end
