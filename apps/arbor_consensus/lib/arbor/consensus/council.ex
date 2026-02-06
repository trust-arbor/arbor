defmodule Arbor.Consensus.Council do
  @moduledoc """
  Council spawning and evaluation collection.

  Spawns one evaluator task per perspective and collects results
  with early termination once quorum is reached.

  ## Flow

  1. Determine required perspectives from config based on `topic`
  2. For each perspective, spawn a Task calling `Evaluator.evaluate/3`
  3. Collect with early termination: return as soon as quorum is reached
  4. All evaluations are sealed before returning
  5. Kill remaining evaluator tasks on quorum
  """

  alias Arbor.Contracts.Consensus.{Evaluation, Proposal}

  require Logger

  @doc """
  Evaluate a proposal by spawning evaluator tasks for each perspective.

  Returns a list of sealed evaluations. Terminates early if quorum
  can be determined before all evaluators complete.

  ## Parameters

    * `proposal` - The proposal to evaluate
    * `evaluators` - Either:
      - A map of `%{perspective => evaluator_module}` for per-perspective routing
      - A list of evaluator modules (perspectives extracted via `perspectives/0`)
      - A single module (same evaluator for all perspectives)
    * `opts` - Options including:
      * `:timeout` - Per-evaluator timeout in ms (default: 90_000)
      * `:evaluator_opts` - Extra opts passed to each evaluator
      * `:quorum` - Required quorum for early termination

  See also: `evaluate/4` for the legacy API that accepts explicit perspectives.
  """
  @spec evaluate(
          proposal :: Proposal.t(),
          evaluators :: map() | [module()] | module(),
          opts :: keyword()
        ) :: {:ok, [Evaluation.t()]} | {:error, term()}
  def evaluate(proposal, evaluators, opts \\ [])

  # Map of perspective => evaluator_module (preferred)
  def evaluate(%Proposal{} = proposal, evaluators, opts) when is_map(evaluators) do
    timeout = Keyword.get(opts, :timeout, 90_000)
    evaluator_opts = Keyword.get(opts, :evaluator_opts, [])
    quorum = Keyword.get(opts, :quorum)

    # Spawn one task per perspective, routing to the correct evaluator
    tasks =
      Enum.map(evaluators, fn {perspective, evaluator_module} ->
        task =
          Task.async(fn ->
            evaluator_module.evaluate(proposal, perspective, evaluator_opts)
          end)

        {perspective, task}
      end)

    # Collect results with early termination
    {evaluations, _remaining} =
      collect_with_early_termination(tasks, quorum, timeout)

    if Enum.empty?(evaluations) do
      {:error, :no_evaluations}
    else
      {:ok, evaluations}
    end
  end

  # List of evaluator modules — build perspective map from each module's perspectives/0
  def evaluate(%Proposal{} = proposal, evaluators, opts) when is_list(evaluators) do
    evaluator_map = build_evaluator_map(evaluators)
    evaluate(proposal, evaluator_map, opts)
  end

  # Single evaluator module (legacy) — get perspectives and build map
  def evaluate(%Proposal{} = proposal, evaluator_backend, opts) when is_atom(evaluator_backend) do
    perspectives = get_evaluator_perspectives(evaluator_backend)
    evaluator_map = Map.new(perspectives, fn p -> {p, evaluator_backend} end)
    evaluate(proposal, evaluator_map, opts)
  end

  @doc """
  Legacy 4-arity API for backwards compatibility.

  `evaluate(proposal, perspectives, evaluator_backend, opts)`

  * `perspectives` - List of perspective atoms (e.g., `[:security, :stability]`)
  * `evaluator_backend` - Single module to use for all perspectives
  """
  def evaluate(%Proposal{} = proposal, perspectives, evaluator_backend, opts)
      when is_list(perspectives) and is_atom(hd(perspectives)) and is_atom(evaluator_backend) do
    evaluator_map = Map.new(perspectives, fn p -> {p, evaluator_backend} end)
    evaluate(proposal, evaluator_map, opts)
  end

  @doc """
  Build a map from perspective to evaluator module.

  Each evaluator declares its perspectives via `perspectives/0`.
  If multiple evaluators declare the same perspective, the first wins.
  """
  @spec build_evaluator_map([module()]) :: %{atom() => module()}
  def build_evaluator_map(evaluators) do
    evaluators
    |> Enum.flat_map(fn evaluator ->
      perspectives = get_evaluator_perspectives(evaluator)
      Enum.map(perspectives, fn p -> {p, evaluator} end)
    end)
    |> Map.new()
  end

  defp get_evaluator_perspectives(evaluator) do
    try do
      if function_exported?(evaluator, :perspectives, 0) do
        evaluator.perspectives()
      else
        []
      end
    rescue
      _ -> []
    end
  end

  @doc """
  Determine the required perspectives for a proposal.

  Returns all non-human perspectives from the Protocol defaults.
  Topic-specific perspective configuration is handled by TopicRegistry.
  """
  @spec required_perspectives(Proposal.t()) :: [atom()]
  def required_perspectives(%Proposal{}) do
    Arbor.Contracts.Consensus.Protocol.perspectives() -- [:human]
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp collect_with_early_termination(tasks, quorum, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(tasks, [], quorum, deadline)
  end

  defp do_collect([], evaluations, _quorum, _deadline) do
    {evaluations, []}
  end

  defp do_collect(remaining_tasks, evaluations, quorum, deadline) do
    now = System.monotonic_time(:millisecond)
    remaining_ms = max(deadline - now, 0)

    cond do
      remaining_ms <= 0 ->
        kill_tasks(remaining_tasks)
        {evaluations, remaining_tasks}

      quorum && quorum_determinable?(evaluations, remaining_tasks, quorum) ->
        kill_tasks(remaining_tasks)
        {evaluations, remaining_tasks}

      true ->
        yield_and_continue(remaining_tasks, evaluations, quorum, deadline, remaining_ms)
    end
  end

  defp yield_and_continue(remaining_tasks, evaluations, quorum, deadline, remaining_ms) do
    task_refs = Enum.map(remaining_tasks, fn {_perspective, task} -> task end)

    case Task.yield_many(task_refs, min(remaining_ms, 5_000)) do
      results when is_list(results) ->
        {new_evals, still_pending} =
          process_yield_results(remaining_tasks, results)

        do_collect(
          still_pending,
          evaluations ++ new_evals,
          quorum,
          deadline
        )
    end
  end

  defp process_yield_results(tasks, results) do
    # Build a map from task ref to result
    result_map =
      Map.new(results, fn {task, result} -> {task.ref, result} end)

    {completed_evals, still_pending} =
      Enum.reduce(tasks, {[], []}, fn {perspective, task} = entry, {evals, pending} ->
        case Map.get(result_map, task.ref) do
          {:ok, {:ok, evaluation}} ->
            {[evaluation | evals], pending}

          {:ok, {:error, reason}} ->
            Logger.warning("Evaluator #{perspective} failed: #{inspect(reason)}")
            {evals, pending}

          {:exit, reason} ->
            Logger.warning("Evaluator #{perspective} crashed: #{inspect(reason)}")
            {evals, pending}

          nil ->
            # Still running
            {evals, [entry | pending]}
        end
      end)

    {Enum.reverse(completed_evals), Enum.reverse(still_pending)}
  end

  defp quorum_determinable?(evaluations, remaining_tasks, quorum) do
    approve_count = Enum.count(evaluations, &(&1.vote == :approve))
    reject_count = Enum.count(evaluations, &(&1.vote == :reject))
    remaining_count = length(remaining_tasks)

    # Quorum reached for approval
    # Quorum reached for rejection
    # Even if all remaining approve, can't reach quorum (guaranteed rejection/deadlock)
    approve_count >= quorum or
      reject_count >= quorum or
      approve_count + remaining_count < quorum
  end

  defp kill_tasks(tasks) do
    Enum.each(tasks, fn {_perspective, task} ->
      Task.shutdown(task, :brutal_kill)
    end)
  end
end
