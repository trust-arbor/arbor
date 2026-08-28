defmodule Arbor.Commands.CodingRunCore do
  @moduledoc """
  Pure state machine for `mix arbor.coding.run`.

  `new/1` constructs state from a decoded plan and operator options.
  `step/2` is a pure transition that returns the next state plus one effect
  as data. `show/1` formats a halt result. The core never receives or invokes
  callbacks; the Mix shell interprets effects and feeds results back as data.

  The shell must set `now_ms` on state before each `step/2` so remaining
  `--max-wait-ms` budget can clamp `{:sleep, ms}` and `{:rpc, …, timeout}`.
  """

  # Upper bound for one commit-gate git inspection; clamped further by the
  # remaining --max-wait-ms budget.
  @git_timeout_ms 10_000

  alias Arbor.Commands.CodingRun.GitStatus
  alias Arbor.Contracts.Coding.{Plan, WorkPacket}

  @default_poll_ms 10_000
  @default_rpc_timeout_ms 60_000
  @default_follow_rpc_timeout_ms 15_000
  @max_approvals_per_response 64
  @max_ignored_ids 256
  @success_codes ~w(change_committed pr_created no_changes)
  @review_code "human_review_required"
  @validation_gate "coding_reviewed_validation"
  @commit_gate "coding_reviewed_commit"
  @ready_statuses ["ready", "degraded", :ready, :degraded]
  @terminal_states [:done, :failed, :cancelled, "done", "failed", "cancelled"]
  @waiting_states [:waiting_approval, "waiting_approval"]
  @allowed_opt_keys [
    :plan,
    :agent_id,
    :caller_id,
    :approve_as_dispatcher,
    :allow_paths,
    :poll_ms,
    :max_wait_ms,
    :now_ms,
    :now_iso,
    :rpc_timeout_ms,
    :follow_rpc_timeout_ms
  ]

  @type phase ::
          :ready
          | :awaiting_readiness
          | :awaiting_dispatch
          | :after_emit
          | :awaiting_status
          | :awaiting_approvals
          | :handling_approval
          | :awaiting_git
          | :awaiting_prompt
          | :following
          | :awaiting_answer
          | :awaiting_result
          | :halted

  @type effect ::
          {:rpc, module(), atom(), [term()], non_neg_integer()}
          | {:emit, String.t()}
          | {:prompt, String.t()}
          | {:sleep, non_neg_integer()}
          | {:git_status_porcelain, String.t(), pos_integer()}
          | {:halt, non_neg_integer(), result()}

  @type result :: %{
          exit_code: non_neg_integer(),
          reason: atom(),
          summary: String.t(),
          task_id: String.t() | nil
        }

  @type approval_view :: %{
          required(String.t()) => String.t() | nil
        }

  @type state :: %{
          phase: phase(),
          envelope: map(),
          agent_id: String.t(),
          caller_id: String.t(),
          approve_as_dispatcher: boolean(),
          allow_paths: Regex.t() | nil,
          poll_ms: pos_integer(),
          deadline_ms: non_neg_integer() | nil,
          now_ms: non_neg_integer(),
          now_iso: String.t() | nil,
          rpc_timeout_ms: pos_integer(),
          follow_rpc_timeout_ms: pos_integer(),
          task_id: String.t() | nil,
          fingerprint: {term(), term()} | nil,
          status: map() | nil,
          approvals: [approval_view()] | nil,
          git: term() | nil,
          approval_queue: [approval_view()],
          current_approval: approval_view() | nil,
          ignored_ids: MapSet.t(),
          pending_effect: effect() | nil,
          emit_return_phase: phase() | nil,
          result: term() | nil
        }

  @doc """
  Construct run state.

  Canonicalizes the decoded plan file to
  `%{"kind" => "coding_change", "plan" => Plan.to_map(plan)}` after digest
  stamping and `Plan.new/1`. A supplied wrapper is validated strictly; a bare
  plan is wrapped.
  """
  @spec new(keyword() | map()) :: {:ok, state()} | {:error, atom() | tuple()}
  def new(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      extra_option_keys?(opts) ->
        {:error, :invalid_options}

      true ->
        build(Map.new(opts))
    end
  end

  def new(opts) when is_map(opts) and not is_struct(opts) do
    new(Map.to_list(opts))
  end

  def new(_opts), do: {:error, :invalid_options}

  @doc """
  Advance the machine. The shell updates `now_ms` on state before calling.

  When remaining `--max-wait-ms` budget is zero, `step/2` halts with exit 1
  before emitting a sleep or RPC.
  """
  @spec step(state() | map(), term()) :: {state(), effect()}
  def step(state, event) when is_map(state) do
    state = normalize_state(state)

    if budget_exhausted?(state) and not halt_event?(event) do
      halt(state, 1, :deadline_exceeded, "max-wait-ms budget exhausted")
    else
      dispatch(state, event)
    end
  end

  def step(_state, _event) do
    halt(initial_state(%{}), 1, :invalid_options, "invalid state")
  end

  @doc "Format a halt result for operator output."
  @spec show(result() | map()) :: String.t()
  def show(%{summary: summary} = result) when is_binary(summary) do
    reason = Map.get(result, :reason, :unknown)
    code = Map.get(result, :exit_code, 1)
    "coding run: #{reason} (exit #{code})\n#{summary}"
  end

  def show(result) when is_map(result) do
    show(%{
      exit_code: Map.get(result, :exit_code, 1),
      reason: Map.get(result, :reason, :invalid_options),
      summary: Map.get(result, :summary) || inspect(result),
      task_id: Map.get(result, :task_id)
    })
  end

  def show(_result),
    do: show(%{exit_code: 1, reason: :invalid_options, summary: "invalid result"})

  defp extra_option_keys?(opts) do
    opts
    |> Keyword.keys()
    |> Enum.any?(fn key -> key not in @allowed_opt_keys end)
  end

  defp build(opts) do
    with {:ok, envelope} <- canonicalize(Map.get(opts, :plan)),
         {:ok, agent_id} <- require_id(Map.get(opts, :agent_id), :agent_id),
         {:ok, caller_id} <- require_id(Map.get(opts, :caller_id), :caller_id),
         {:ok, approve?} <- require_bool(Map.get(opts, :approve_as_dispatcher, false)),
         {:ok, allow_paths} <- compile_allow_paths(Map.get(opts, :allow_paths)),
         {:ok, poll_ms} <- require_pos(Map.get(opts, :poll_ms, @default_poll_ms), :poll_ms),
         {:ok, max_wait_ms} <- optional_pos(Map.get(opts, :max_wait_ms), :max_wait_ms),
         {:ok, now_ms} <- require_non_neg(Map.get(opts, :now_ms, 0), :now_ms),
         {:ok, rpc_timeout} <-
           require_pos(Map.get(opts, :rpc_timeout_ms, @default_rpc_timeout_ms), :rpc_timeout_ms),
         {:ok, follow_timeout} <-
           require_pos(
             Map.get(opts, :follow_rpc_timeout_ms, @default_follow_rpc_timeout_ms),
             :follow_rpc_timeout_ms
           ) do
      deadline_ms =
        case max_wait_ms do
          nil -> nil
          wait -> now_ms + wait
        end

      state =
        initial_state(%{
          envelope: envelope,
          agent_id: agent_id,
          caller_id: caller_id,
          approve_as_dispatcher: approve?,
          allow_paths: allow_paths,
          poll_ms: poll_ms,
          deadline_ms: deadline_ms,
          now_ms: now_ms,
          now_iso: iso_or_nil(Map.get(opts, :now_iso)),
          rpc_timeout_ms: rpc_timeout,
          follow_rpc_timeout_ms: follow_timeout
        })

      {:ok, state}
    end
  end

  defp canonicalize(decoded) when is_map(decoded) and not is_struct(decoded) do
    with {:ok, plan_attrs} <- extract_plan_attrs(decoded),
         {:ok, plan_attrs} <- stamp_digest(plan_attrs),
         {:ok, plan} <- Plan.new(plan_attrs) do
      {:ok, %{"kind" => "coding_change", "plan" => Plan.to_map(plan)}}
    end
  end

  defp canonicalize(_decoded), do: {:error, :invalid_plan}

  defp extract_plan_attrs(decoded) do
    if Map.has_key?(decoded, "kind") or Map.has_key?(decoded, "plan") do
      validate_wrapper(decoded)
    else
      {:ok, decoded}
    end
  end

  defp validate_wrapper(wrapper) do
    extra = Map.drop(wrapper, ["kind", "plan"])

    cond do
      map_size(extra) > 0 ->
        {:error, :invalid_wrapper}

      wrapper["kind"] != "coding_change" ->
        {:error, :invalid_wrapper}

      not is_map(wrapper["plan"]) or is_struct(wrapper["plan"]) ->
        {:error, :invalid_wrapper}

      true ->
        {:ok, wrapper["plan"]}
    end
  end

  defp stamp_digest(plan) do
    packet = Map.get(plan, "work_packet")
    digest = Map.get(plan, "work_packet_digest")

    cond do
      is_nil(packet) ->
        {:ok, plan}

      is_binary(digest) and digest != "" ->
        {:ok, plan}

      true ->
        case WorkPacket.digest(packet) do
          {:ok, stamped} -> {:ok, Map.put(plan, "work_packet_digest", stamped)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp initial_state(overrides) do
    Map.merge(
      %{
        phase: :ready,
        envelope: %{},
        agent_id: "",
        caller_id: "",
        approve_as_dispatcher: false,
        allow_paths: nil,
        poll_ms: @default_poll_ms,
        deadline_ms: nil,
        now_ms: 0,
        now_iso: nil,
        rpc_timeout_ms: @default_rpc_timeout_ms,
        follow_rpc_timeout_ms: @default_follow_rpc_timeout_ms,
        task_id: nil,
        fingerprint: nil,
        status: nil,
        approvals: nil,
        git: nil,
        approval_queue: [],
        current_approval: nil,
        ignored_ids: MapSet.new(),
        pending_effect: nil,
        emit_return_phase: nil,
        result: nil
      },
      overrides
    )
  end

  defp normalize_state(state) do
    defaults = initial_state(%{})

    Enum.reduce(Map.keys(defaults), defaults, fn key, acc ->
      Map.put(acc, key, Map.get(state, key, Map.fetch!(defaults, key)))
    end)
  end

  defp halt_event?(:continue), do: false
  defp halt_event?(_event), do: false

  defp dispatch(%{phase: :after_emit} = state, :continue) do
    phase = state.emit_return_phase || :following
    state = %{state | phase: phase, emit_return_phase: nil}

    case state.pending_effect do
      nil ->
        dispatch(%{state | pending_effect: nil}, :continue)

      effect ->
        {%{state | pending_effect: nil}, effect}
    end
  end

  defp dispatch(state, :start), do: request_readiness(state)

  defp dispatch(%{phase: :awaiting_readiness} = state, {:readiness, report}),
    do: on_readiness(state, report)

  defp dispatch(%{phase: :awaiting_dispatch} = state, {:dispatch, result}),
    do: on_dispatch(state, result)

  defp dispatch(%{phase: :awaiting_status} = state, {:status, result}),
    do: on_status(state, result)

  defp dispatch(%{phase: :awaiting_approvals} = state, {:approvals, result}),
    do: on_approvals(state, result)

  defp dispatch(%{phase: :awaiting_git} = state, {:git_status, result}),
    do: on_git_status(state, result)

  defp dispatch(%{phase: :awaiting_prompt} = state, {:prompt_reply, yes?}),
    do: on_prompt_reply(state, yes?)

  defp dispatch(%{phase: :awaiting_answer} = state, {:answer, result}),
    do: on_answer(state, result)

  defp dispatch(%{phase: :awaiting_result} = state, {:result, result}),
    do: on_result(state, result)

  defp dispatch(%{phase: :following} = state, :continue), do: request_status(state)
  defp dispatch(%{phase: :handling_approval} = state, :continue), do: next_approval(state)
  defp dispatch(state, :slept), do: request_status(state)
  defp dispatch(state, :continue), do: maybe_pending(state)
  defp dispatch(state, _event), do: halt(state, 1, :invalid_options, "invalid step")

  defp maybe_pending(%{pending_effect: effect} = state) when not is_nil(effect) do
    {%{state | pending_effect: nil}, effect}
  end

  defp maybe_pending(state), do: halt(state, 1, :invalid_options, "invalid continue")

  defp request_readiness(state) do
    case budget_timeout(state, state.rpc_timeout_ms) do
      {:ok, timeout} ->
        {%{state | phase: :awaiting_readiness},
         {:rpc, Arbor.Agent, :coding_dispatch_readiness,
          [state.caller_id, state.agent_id, state.envelope, []], timeout}}

      halted ->
        halted
    end
  end

  defp on_readiness(state, {:ok, report}) when is_map(report) do
    case executor_status(report) do
      {:ok, status} when status in @ready_statuses ->
        request_dispatch(state)

      {:ok, _status} ->
        halt(
          state,
          1,
          :readiness_blocked,
          "executor readiness is not ready/degraded\n#{format_diagnostics(report)}"
        )

      :error ->
        halt(
          state,
          1,
          :readiness_malformed,
          "executor readiness missing or malformed\n#{format_diagnostics(report)}"
        )
    end
  end

  defp on_readiness(state, report) do
    halt(state, 1, :readiness_unavailable, "readiness transport error: #{inspect(report)}")
  end

  defp executor_status(%{"planes" => %{"executor" => %{"status" => status}}})
       when status in @ready_statuses or is_binary(status) or is_atom(status) do
    {:ok, status}
  end

  defp executor_status(%{"planes" => planes}) when is_map(planes) do
    if Map.has_key?(planes, "executor"), do: {:ok, :malformed}, else: :error
  end

  defp executor_status(_report), do: :error

  defp request_dispatch(state) do
    case budget_timeout(state, state.rpc_timeout_ms) do
      {:ok, timeout} ->
        {%{state | phase: :awaiting_dispatch},
         {:rpc, Arbor.Agent, :dispatch_task,
          [state.caller_id, state.agent_id, state.envelope, []], timeout}}

      halted ->
        halted
    end
  end

  defp on_dispatch(state, {:ok, task_id}) when is_binary(task_id) and task_id != "" do
    state = %{state | task_id: task_id}

    case request_status(state) do
      {state, {:halt, _, _} = halt} ->
        halt_pair(state, halt)

      {state, effect} ->
        emit_then(state, "task_id #{task_id}", effect)
    end
  end

  defp on_dispatch(state, result) do
    halt(state, 1, :dispatch_failed, "dispatch failed: #{inspect(result)}")
  end

  defp request_status(state) do
    case budget_timeout(state, state.follow_rpc_timeout_ms) do
      {:ok, timeout} ->
        {%{state | phase: :awaiting_status}, request_status_effect(state, timeout)}

      halted ->
        halted
    end
  end

  defp request_status_effect(state, timeout) do
    {:rpc, Arbor.Agent.Orchestration, :task_status, [state.task_id, [caller_id: state.caller_id]],
     timeout}
  end

  defp on_status(state, {:ok, status}) when is_map(status) do
    state = %{state | status: status}
    task_state = Map.get(status, :state)
    step = Map.get(status, :current_step)
    fingerprint = {task_state, step}
    changed? = fingerprint != state.fingerprint
    state = %{state | fingerprint: fingerprint}

    cond do
      task_state in @terminal_states ->
        maybe_emit_status(state, status, changed?, :request_result)

      task_state in @waiting_states ->
        maybe_emit_status(state, status, changed?, :request_approvals)

      true ->
        maybe_emit_status(state, status, changed?, :sleep_then_poll)
    end
  end

  defp on_status(state, result) do
    halt(state, 1, :status_failed, "task_status failed: #{inspect(result)}")
  end

  defp maybe_emit_status(state, status, true, next_tag) do
    {state, next_effect} = apply_status_next(state, next_tag)

    emit_then(
      %{state | pending_effect: next_effect},
      format_status_line(state, status),
      next_effect
    )
  end

  defp maybe_emit_status(state, _status, false, next_tag), do: apply_status_next(state, next_tag)

  defp apply_status_next(state, :request_result), do: request_result(state)
  defp apply_status_next(state, :request_approvals), do: request_approvals(state)
  defp apply_status_next(state, :sleep_then_poll), do: sleep_then_poll(state)

  defp format_status_line(state, status) do
    ts = state.now_iso || Integer.to_string(state.now_ms)
    step = Map.get(status, :current_step)
    "#{ts} #{Map.get(status, :state)} #{inspect(step)}"
  end

  defp request_approvals(state) do
    case budget_timeout(state, state.follow_rpc_timeout_ms) do
      {:ok, timeout} ->
        {%{state | phase: :awaiting_approvals},
         {:rpc, Arbor.Agent.Orchestration, :list_pending_approvals,
          [[caller_id: state.caller_id, task_id: state.task_id]], timeout}}

      halted ->
        halted
    end
  end

  defp on_approvals(state, {:ok, list}) when is_list(list) do
    views =
      list
      |> Enum.take(@max_approvals_per_response)
      |> Enum.map(& &1)

    state = %{state | approvals: views}
    {owned, ignored, ignored_ids} = partition_approvals(views, state.task_id, state.ignored_ids)
    state = %{state | ignored_ids: ignored_ids, approval_queue: owned, phase: :handling_approval}

    case ignored do
      [first | rest] ->
        text = Enum.map_join([first | rest], "\n", &ignored_line/1)
        emit_then(state, text, nil)

      [] ->
        next_approval(state)
    end
  end

  defp on_approvals(state, result) do
    halt(state, 1, :approvals_failed, "list_pending_approvals failed: #{inspect(result)}")
  end

  defp next_approval(%{approval_queue: []} = state) do
    sleep_then_poll(%{state | current_approval: nil, phase: :following})
  end

  defp next_approval(%{approval_queue: [approval | rest]} = state) do
    state = %{state | approval_queue: rest, current_approval: approval}
    listing = format_approval_listing(approval)

    cond do
      state.approve_as_dispatcher and approval["action"] == @validation_gate ->
        emit_then(
          %{state | phase: :awaiting_answer},
          listing,
          request_answer_effect(state, approval)
        )

      state.approve_as_dispatcher and approval["action"] == @commit_gate ->
        request_git(state, approval, listing)

      true ->
        prompt_approval(state, approval, listing)
    end
  end

  defp request_git(state, approval, listing) do
    worktree = approval["worktree"]

    if is_binary(worktree) and worktree != "" do
      # The git inspection is bounded by the smaller of its own 10 s cap and
      # whatever remains of --max-wait-ms; with nothing left it never starts.
      case clamp_timeout(state, @git_timeout_ms) do
        0 ->
          halt(state, 1, :deadline_exceeded, "deadline exceeded before commit-gate inspection")

        timeout_ms ->
          effect = {:git_status_porcelain, worktree, timeout_ms}
          emit_then(%{state | phase: :awaiting_git}, listing, effect)
      end
    else
      halt(state, 1, :missing_worktree, "commit gate missing worktree; not answering")
    end
  end

  defp prompt_approval(state, approval, listing) do
    text = listing <> "\nApprove #{approval["id"]}? [y/N]"
    {%{state | phase: :awaiting_prompt}, {:prompt, text}}
  end

  defp on_git_status(state, {:ok, binary}) when is_binary(binary) do
    state = %{state | git: {:ok, binary}}

    case GitStatus.decode(binary) do
      {:ok, paths} ->
        decide_commit_paths(state, paths)

      {:error, reason} ->
        halt(state, 1, :git_malformed, "git status malformed (#{reason}); not answering")
    end
  end

  defp on_git_status(state, {:error, reason}) do
    state = %{state | git: {:error, reason}}
    halt(state, 1, :git_failed, "git status failed (#{reason}); not answering")
  end

  defp on_git_status(state, other) do
    state = %{state | git: other}
    halt(state, 1, :git_failed, "git status failed (#{inspect(other)}); not answering")
  end

  defp decide_commit_paths(state, paths) do
    listing = format_path_list(paths)

    if paths_allowed?(paths, state.allow_paths) do
      approval = state.current_approval

      emit_then(
        %{state | phase: :awaiting_answer},
        listing,
        request_answer_effect(state, approval)
      )
    else
      text = listing <> "\nUNEXPECTED FILES"
      halt_after_emit(state, text, 1, :unexpected_files, text)
    end
  end

  defp paths_allowed?([], _regex), do: true
  defp paths_allowed?(_paths, nil), do: false

  defp paths_allowed?(paths, %Regex{} = regex) do
    Enum.all?(paths, &Regex.match?(regex, &1))
  end

  defp paths_allowed?(_paths, _regex), do: false

  defp on_prompt_reply(state, true) do
    request_answer(state, state.current_approval)
  end

  defp on_prompt_reply(state, false) do
    halt(state, 1, :approval_declined, "operator declined approval; not answering")
  end

  defp request_answer(state, approval) do
    case budget_timeout(state, state.follow_rpc_timeout_ms) do
      {:ok, timeout} ->
        {%{state | phase: :awaiting_answer}, request_answer_effect(state, approval, timeout)}

      halted ->
        halted
    end
  end

  defp request_answer_effect(state, approval, timeout \\ nil) do
    timeout = timeout || clamp_timeout(state, state.follow_rpc_timeout_ms)

    {:rpc, Arbor.Agent.Orchestration, :answer_approval,
     [approval["id"], :approve, [caller_id: state.caller_id]], timeout}
  end

  defp on_answer(state, :ok), do: next_approval(state)
  defp on_answer(state, {:ok, _}), do: next_approval(state)

  defp on_answer(state, result) do
    halt(state, 1, :answer_failed, "answer_approval failed: #{inspect(result)}")
  end

  defp request_result(state) do
    case budget_timeout(state, state.follow_rpc_timeout_ms) do
      {:ok, timeout} ->
        {%{state | phase: :awaiting_result},
         {:rpc, Arbor.Agent.Orchestration, :task_result,
          [state.task_id, [caller_id: state.caller_id]], timeout}}

      halted ->
        halted
    end
  end

  defp on_result(state, result) do
    state = %{state | result: result}
    {exit_code, reason, summary} = format_task_result(result)
    halt(state, exit_code, reason, summary)
  end

  defp sleep_then_poll(state) do
    case budget_timeout(state, state.poll_ms) do
      {:ok, ms} -> {%{state | phase: :following}, {:sleep, ms}}
      halted -> halted
    end
  end

  defp budget_timeout(state, desired) do
    timeout = clamp_timeout(state, desired)

    if timeout <= 0 do
      halt(state, 1, :deadline_exceeded, "max-wait-ms budget exhausted")
    else
      {:ok, timeout}
    end
  end

  defp budget_exhausted?(%{deadline_ms: nil}), do: false

  defp budget_exhausted?(%{deadline_ms: deadline, now_ms: now})
       when is_integer(deadline) and is_integer(now) do
    now >= deadline
  end

  defp budget_exhausted?(_state), do: false

  defp remaining_ms(%{deadline_ms: nil}), do: :infinity

  defp remaining_ms(%{deadline_ms: deadline, now_ms: now})
       when is_integer(deadline) and is_integer(now) and deadline > now do
    deadline - now
  end

  defp remaining_ms(_state), do: 0

  defp clamp_timeout(state, desired) do
    case remaining_ms(state) do
      :infinity -> desired
      0 -> 0
      rem -> min(desired, rem)
    end
  end

  defp emit_then(state, text, next_effect) do
    {%{state | emit_return_phase: state.phase, phase: :after_emit, pending_effect: next_effect},
     {:emit, text}}
  end

  defp halt_pair(_state, halt), do: halt

  defp halt_after_emit(state, text, code, reason, summary) do
    {_state, halt_effect} = halt(state, code, reason, summary)
    emit_then(state, text, halt_effect)
  end

  defp halt(state, code, reason, summary) do
    result = %{
      exit_code: code,
      reason: reason,
      summary: summary,
      task_id: state.task_id
    }

    {%{state | phase: :halted, result: result}, {:halt, code, result}}
  end

  defp partition_approvals(views, task_id, ignored_ids) do
    Enum.reduce(views, {[], [], ignored_ids}, fn view, {owned, ignored, seen} ->
      cond do
        not valid_approval_view?(view) ->
          {owned, ignored, seen}

        view["task_id"] == task_id and is_binary(task_id) and task_id != "" ->
          {owned ++ [view], ignored, seen}

        true ->
          id = view["id"]

          if is_binary(id) and MapSet.member?(seen, id) do
            {owned, ignored, seen}
          else
            seen = remember_ignored(seen, id)
            {owned, ignored ++ [view], seen}
          end
      end
    end)
  end

  defp remember_ignored(seen, id) when is_binary(id) do
    seen = MapSet.put(seen, id)

    if MapSet.size(seen) <= @max_ignored_ids do
      seen
    else
      seen
      |> MapSet.to_list()
      |> Enum.take(@max_ignored_ids)
      |> MapSet.new()
    end
  end

  defp remember_ignored(seen, _id), do: seen

  defp valid_approval_view?(%{"id" => id, "action" => action})
       when is_binary(id) and id != "" and is_binary(action) do
    true
  end

  defp valid_approval_view?(_view), do: false

  defp ignored_line(view) do
    "ignored approval #{view["id"]}: task id #{inspect(view["task_id"])} is not this task"
  end

  defp format_approval_listing(view) do
    "approval id=#{view["id"]} action=#{view["action"]} worktree=#{view["worktree"] || "(none)"}"
  end

  defp format_path_list([]), do: "changed paths: (none)"

  defp format_path_list(paths) do
    "changed paths:\n" <> Enum.join(paths, "\n")
  end

  defp format_diagnostics(report) when is_map(report) do
    executor = get_in(report, ["planes", "executor"])
    "diagnostics: #{inspect(executor || report)}"
  end

  defp format_diagnostics(other), do: "diagnostics: #{inspect(other)}"

  defp format_task_result({:ok, result}) do
    fields = extract_ok_fields(result)
    {exit_for(fields.code), :terminal, render_summary(fields, :ok)}
  end

  defp format_task_result({:error, map}) when is_map(map) do
    fields = extract_error_fields(map)
    {exit_for(fields.code), :terminal_error, render_summary(fields, :error)}
  end

  defp format_task_result({:error, :cancelled}) do
    fields = %{
      code: "cancelled",
      disposition: "cancelled",
      origin: nil,
      retry: nil,
      failure_reason: "cancelled",
      commit: nil,
      branch: nil,
      evidence_ref: nil,
      verdict: nil,
      seats: []
    }

    {1, :cancelled, render_summary(fields, :error)}
  end

  defp format_task_result({:error, {:failed, reason}}) do
    fields = %{
      code: "failed",
      disposition: "failed",
      origin: nil,
      retry: nil,
      failure_reason: inspect(reason),
      commit: nil,
      branch: nil,
      evidence_ref: nil,
      verdict: nil,
      seats: []
    }

    {1, :failed, render_summary(fields, :error)}
  end

  defp format_task_result({:error, {:waiting_approval, approval_id}}) do
    {1, :transport_error, "transport error: #{inspect({:waiting_approval, approval_id})}"}
  end

  defp format_task_result({:badrpc, reason}) do
    {1, :transport_error, "transport error: #{inspect({:badrpc, reason})}"}
  end

  defp format_task_result(other) do
    {1, :transport_error, "transport error: #{inspect(other)}"}
  end

  defp extract_ok_fields(%{"outcome" => outcome} = result) when is_map(outcome) do
    evidence = Map.get(result, "evidence")
    evidence = if is_map(evidence), do: evidence, else: %{}
    payload = Map.get(evidence, "result")
    payload = if is_map(payload), do: payload, else: %{}

    %{
      code: outcome["code"],
      disposition: outcome["disposition"],
      origin: outcome["origin"],
      retry: outcome["retry"],
      failure_reason: outcome["message"],
      commit: payload["commit"],
      branch: payload["branch"],
      evidence_ref: outcome["evidence_ref"],
      verdict: payload["verdict"],
      seats: evaluations(payload["evaluations"])
    }
  end

  defp extract_ok_fields(%{result_type: :coding_change, payload: payload}) when is_map(payload) do
    outcome = payload[:outcome]
    outcome = if is_map(outcome), do: outcome, else: %{}

    %{
      code: outcome["code"],
      disposition: outcome["disposition"],
      origin: outcome["origin"],
      retry: outcome["retry"],
      failure_reason: outcome["message"],
      commit: payload[:commit],
      branch: payload[:branch],
      evidence_ref: payload[:evidence_ref],
      verdict: payload[:verdict],
      seats: evaluations(payload[:evaluations])
    }
  end

  defp extract_ok_fields(result) do
    %{
      code: nil,
      disposition: nil,
      origin: nil,
      retry: nil,
      failure_reason: inspect(result),
      commit: nil,
      branch: nil,
      evidence_ref: nil,
      verdict: nil,
      seats: []
    }
  end

  defp extract_error_fields(map) do
    outcome =
      case Map.get(map, "outcome") do
        nested when is_map(nested) -> nested
        code when is_binary(code) -> %{"code" => code}
        _other -> %{}
      end

    %{
      code: outcome["code"],
      disposition: Map.get(map, "disposition") || outcome["disposition"],
      origin: Map.get(map, "origin") || outcome["origin"],
      retry: Map.get(map, "retry") || outcome["retry"],
      failure_reason: Map.get(map, "failure_reason") || outcome["message"],
      commit: Map.get(map, "commit"),
      branch: Map.get(map, "branch"),
      evidence_ref: Map.get(map, "evidence_ref") || outcome["evidence_ref"],
      verdict: Map.get(map, "verdict"),
      seats: evaluations(Map.get(map, "evaluations"))
    }
  end

  defp evaluations(list) when is_list(list), do: Enum.map(list, &seat_view/1)
  defp evaluations(_list), do: []

  defp seat_view(map) when is_map(map) do
    %{
      seat: Map.get(map, "seat"),
      vote: Map.get(map, "vote"),
      provider: Map.get(map, "provider"),
      model: Map.get(map, "model")
    }
  end

  defp seat_view(_map) do
    %{seat: nil, vote: nil, provider: nil, model: nil}
  end

  defp exit_for(code) when code in @success_codes, do: 0
  defp exit_for(@review_code), do: 2
  defp exit_for(_code), do: 1

  defp render_summary(fields, kind) do
    seats =
      Enum.map_join(fields.seats, "\n", fn seat ->
        "seat=#{seat.seat} vote=#{seat.vote} provider=#{seat.provider} model=#{seat.model}"
      end)

    seats = if seats == "", do: "seats: (none)", else: seats

    Enum.join(
      [
        "outcome: #{fields.code}",
        "disposition: #{fields.disposition}",
        "origin: #{fields.origin}",
        "retry: #{fields.retry}",
        "verdict: #{inspect(fields.verdict)}",
        seats,
        "commit: #{fields.commit}",
        "branch: #{fields.branch}",
        "evidence_ref: #{fields.evidence_ref}",
        "failure_reason: #{fields.failure_reason}",
        "result_kind: #{kind}"
      ],
      "\n"
    )
  end

  defp require_id(value, _field)
       when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.valid?(value) and String.trim(value) == value and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, :invalid_options}
  end

  defp require_id(_value, _field), do: {:error, :invalid_options}

  defp require_bool(value) when is_boolean(value), do: {:ok, value}
  defp require_bool(_value), do: {:error, :invalid_options}

  defp require_pos(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp require_pos(_value, _field), do: {:error, :invalid_options}

  defp require_non_neg(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}
  defp require_non_neg(_value, _field), do: {:error, :invalid_options}

  defp optional_pos(nil, _field), do: {:ok, nil}
  defp optional_pos(value, field), do: require_pos(value, field)

  defp compile_allow_paths(nil), do: {:ok, nil}

  defp compile_allow_paths(pattern) when is_binary(pattern) do
    if byte_size(pattern) > 256 do
      {:error, :invalid_allow_paths}
    else
      # Operator flag, length-capped. Compiled once at new/1.
      # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
      case Regex.compile(pattern) do
        {:ok, regex} -> {:ok, regex}
        {:error, _reason} -> {:error, :invalid_allow_paths}
      end
    end
  end

  defp compile_allow_paths(%Regex{} = regex), do: {:ok, regex}
  defp compile_allow_paths(_pattern), do: {:error, :invalid_allow_paths}

  defp iso_or_nil(value) when is_binary(value), do: value
  defp iso_or_nil(_value), do: nil
end
