defmodule Arbor.Agent.Eval.TaskEval do
  @moduledoc """
  v3 Real-Bug Memory Ablation Eval.

  Runs a real diagnostician agent against a real bug (checked out in a git
  worktree) through the real Session/DOT heartbeat pipeline. The DOT pipeline
  variant controls which memory subsystems persist between heartbeats.

  Completion: agent submits a proposal (via tool call or proposal queue).
  We evaluate proposal quality via keyword scoring and optionally council verdict.

  ## Usage

      TaskEval.run(variants: [:bare, :full], max_heartbeats: 15)
      TaskEval.run(bug: :glob_wildcard, model: "anthropic/claude-3-5-haiku-latest")
  """

  alias Arbor.Agent.BranchSupervisor
  alias Arbor.Agent.Eval.{BugCase, ProposalScorer, ProviderRoutePin}
  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Manager
  alias Arbor.Contracts.Session.HeartbeatResult
  alias Arbor.LLM.OpenCodeZen

  require Logger

  @default_max_heartbeats 15
  @default_model "openrouter/anthropic/claude-3-5-haiku-latest"
  @default_provider :openrouter
  @default_variants [:bare, :full]
  # Signals are observability, not lifecycle tracking. Count admitted
  # HeartbeatService completions (last_completed_at) instead.
  @heartbeat_poll_ms 250
  # Gap between *counted* HeartbeatService completions. Failed beats (503)
  # do not reset it. Zen call+followup can each take ~3 minutes, and a 503
  # plus retry of the next beat can exceed 5 minutes while still in flight.
  @heartbeat_wait_ms 720_000

  @variant_dots %{
    bare: "heartbeat-bare.dot",
    goals: "heartbeat-goals.dot",
    notes: "heartbeat-notes.dot",
    identity: "heartbeat-identity.dot",
    full: "heartbeat-full.dot"
  }

  # -- Public API --

  @doc """
  Run the full task eval.

  ## Options

    * `:bug` — bug case ID (default: :glob_wildcard)
    * `:variants` — list of variant atoms (default: [:bare, :full])
    * `:max_heartbeats` — max heartbeats before giving up (default: 15)
    * `:reps` — repetitions per variant (default: 1)
    * `:model` — LLM model string (default: haiku via openrouter)
    * `:provider` — LLM provider atom (default: :openrouter)
    * `:council` — enable council evaluation (default: false)
    * `:tag` — persistence tag (default: nil)
    * `:context_management` — context management mode for SimpleAgent trials:
      `:none`, `:heuristic`, `:full` (default: `:none`)
  """
  def run(opts \\ []) do
    bug_id = Keyword.get(opts, :bug, :glob_wildcard)
    variants = Keyword.get(opts, :variants, @default_variants)
    max_heartbeats = Keyword.get(opts, :max_heartbeats, @default_max_heartbeats)
    reps = Keyword.get(opts, :reps, 1)
    tag = Keyword.get(opts, :tag)

    with {:ok, bug} <- BugCase.get(bug_id),
         {:ok, worktree_path} <- create_worktree(bug) do
      Logger.info("[TaskEval] Worktree ready at #{worktree_path}")

      results =
        for variant <- variants, rep <- 1..reps do
          Logger.info(
            "[TaskEval] Running variant=#{variant}, rep=#{rep}/#{reps}, " <>
              "max_hb=#{max_heartbeats}"
          )

          case run_trial(
                 bug,
                 variant,
                 worktree_path,
                 Keyword.merge(opts, max_heartbeats: max_heartbeats)
               ) do
            {:ok, trial_result} ->
              persist_trial(trial_result, variant, rep, tag, opts)
              trial_result

            {:error, reason} ->
              Logger.error("[TaskEval] Trial failed: #{inspect(reason)}")
              %{variant: variant, rep: rep, error: reason}
          end
        end

      cleanup_worktree(bug)
      summary = build_summary(results, variants)
      {:ok, summary}
    end
  end

  # -- Single Trial --

  @doc false
  def run_trial(bug, variant, worktree_path, opts) do
    max_heartbeats = Keyword.get(opts, :max_heartbeats, @default_max_heartbeats)
    model = Keyword.get(opts, :model, @default_model)
    provider = Keyword.get(opts, :provider, @default_provider)
    council? = Keyword.get(opts, :council, false)

    dot_path = resolve_dot_path(variant)
    directive = build_directive(bug, worktree_path)

    trial_start = System.monotonic_time(:millisecond)

    # Use Process dictionary to track agent_id across try/after boundary
    Process.put(:eval_agent_id, nil)

    try do
      # Start a real diagnostician agent with variant DOT
      {:ok, agent_id, _pid} = start_eval_agent(model, provider, dot_path, directive)
      Process.put(:eval_agent_id, agent_id)
      Logger.info("[TaskEval] Agent #{agent_id} started for variant #{variant}")

      register_eval_zen_probes!(agent_id, model, provider)

      # Diagnostician has no fs/read. The glob bug lives in the eval worktree;
      # without a path-scoped grant, file.read is unauthorized even after the
      # JSON-params execute_batch fix.
      grant_eval_worktree_access!(agent_id, worktree_path)

      # Diagnostician baseline is :ask. Heartbeat exec nodes (prune_stale_intents)
      # then wait 60s for a human and the beat is counted as a failure.
      relax_eval_trust!(agent_id)

      # Seed the bug goal
      seed_bug_goal(agent_id, bug)

      case heartbeat_loop(agent_id, bug, max_heartbeats, council?) do
        {:error, reason} ->
          {:error, reason}

        result when is_map(result) ->
          elapsed = System.monotonic_time(:millisecond) - trial_start

          {:ok,
           Map.merge(result, %{
             variant: variant,
             agent_id: agent_id,
             duration_ms: elapsed,
             model: model,
             provider: provider
           })}
      end
    after
      cleanup_id = Process.get(:eval_agent_id)

      if cleanup_id do
        cleanup_eval_principal(cleanup_id)
      end

      Process.delete(:eval_agent_id)
    end
  rescue
    e ->
      Logger.error("[TaskEval] Trial crashed: #{Exception.message(e)}")
      {:error, {:trial_crash, Exception.message(e)}}
  end

  # -- Heartbeat Loop --

  defp heartbeat_loop(agent_id, bug, max_heartbeats, council?) do
    do_heartbeat_loop(agent_id, bug, max_heartbeats, council?, %{
      agent_id: agent_id,
      heartbeat_count: 0,
      heartbeats: [],
      proposal_submitted: false,
      proposal_text: nil,
      proposal_quality: nil,
      council_verdict: nil,
      judge_verdict: nil,
      file_reads: 0,
      unique_files: MapSet.new(),
      total_actions: 0,
      last_completed_at: nil,
      wait_deadline_ms: System.monotonic_time(:millisecond) + @heartbeat_wait_ms
    })
  end

  defp do_heartbeat_loop(_agent_id, bug, max, _council?, state)
       when state.heartbeat_count >= max do
    finalize_trial(state, bug)
  end

  defp do_heartbeat_loop(agent_id, bug, max, council?, state) do
    remaining = state.wait_deadline_ms - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("[TaskEval] Heartbeat timeout after 12 minutes")

      case wait_timeout_result(state.heartbeat_count) do
        {:error, reason} = error ->
          Logger.error("[TaskEval] Infrastructure failure: #{inspect(reason)}")
          error

        :finalize ->
          finalize_trial(state, bug)
      end
    else
      case poll_heartbeat(heartbeat_service_pid(agent_id), state.last_completed_at) do
        {:ok, completed_at, hb_data} ->
          admit_observed_heartbeat(agent_id, bug, max, council?, state, completed_at, hb_data)

        :none ->
          Process.sleep(min(@heartbeat_poll_ms, remaining))
          do_heartbeat_loop(agent_id, bug, max, council?, state)
      end
    end
  end

  defp admit_observed_heartbeat(agent_id, bug, max, council?, state, completed_at, hb_data) do
    hb_num = state.heartbeat_count + 1
    actions = extract_actions(hb_data)

    Logger.info(
      "[TaskEval] Heartbeat #{hb_num}/#{max} — " <>
        "actions=#{length(actions)}, mode=#{hb_data[:cognitive_mode]}"
    )

    new_state =
      state
      |> accumulate_heartbeat(hb_data, hb_num)
      |> Map.put(:last_completed_at, completed_at)
      |> Map.put(:wait_deadline_ms, System.monotonic_time(:millisecond) + @heartbeat_wait_ms)

    if proposal_submitted?(agent_id, hb_data) do
      proposal_text = extract_proposal_text(agent_id, hb_data)
      score = ProposalScorer.score(proposal_text, bug)

      council_verdict =
        if council? do
          case ProposalScorer.council_evaluate(proposal_text, bug) do
            {:ok, verdict} -> verdict
            _ -> nil
          end
        end

      judge_verdict =
        if council? do
          case ProposalScorer.judge_score(proposal_text, bug) do
            {:ok, verdict} -> verdict
            _ -> nil
          end
        end

      new_state
      |> Map.merge(%{
        proposal_submitted: true,
        proposal_text: proposal_text,
        proposal_quality: score,
        council_verdict: council_verdict,
        judge_verdict: judge_verdict
      })
      |> finalize_trial(bug)
    else
      do_heartbeat_loop(agent_id, bug, max, council?, new_state)
    end
  end

  @doc false
  @spec poll_heartbeat(pid() | nil, DateTime.t() | nil) ::
          {:ok, DateTime.t(), map()} | :none
  def poll_heartbeat(nil, _last_seen), do: :none

  def poll_heartbeat(server, last_seen) when is_pid(server) do
    # HeartbeatService.get_state/1 is GenServer.call(server, :get_state).
    # Call the contract directly so arbor_agent tests can use a stub owner
    # without depending on arbor_orchestrator.
    case GenServer.call(server, :get_state, 1_000) do
      %{heartbeat_last_completed_at: %DateTime{} = at} = hb_state ->
        if at != last_seen do
          {:ok, at, heartbeat_payload(hb_state)}
        else
          :none
        end

      _ ->
        :none
    end
  rescue
    _ -> :none
  catch
    :exit, _ -> :none
  end

  defp heartbeat_service_pid(agent_id) do
    case BranchSupervisor.child_pids(agent_id) do
      %{heartbeat_service: pid} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp heartbeat_payload(%{heartbeat_last_result: result, agent_id: agent_id}) do
    ctx = Map.get(result, :context) || %{}
    proposals = List.wrap(Map.get(ctx, "session.proposals") || [])

    result
    |> then(&HeartbeatResult.from_result_ctx(%{agent_id: agent_id}, &1))
    |> HeartbeatResult.to_signal_data()
    |> Map.put(:proposals, proposals)
    |> Map.put(
      :fix_proposal,
      authored_fix_text(%{
        proposals: proposals,
        fix_proposal: Map.get(ctx, "session.fix_proposal")
      })
    )
  rescue
    _ -> %{}
  end

  defp accumulate_heartbeat(state, hb_data, hb_num) do
    # Count file reads and unique files from actions
    actions = extract_actions(hb_data)
    file_reads = Enum.count(actions, &file_read_action?/1)
    files_read = actions |> Enum.filter(&file_read_action?/1) |> Enum.map(&extract_file_path/1)

    %{
      state
      | heartbeat_count: hb_num,
        heartbeats: state.heartbeats ++ [hb_data],
        file_reads: state.file_reads + file_reads,
        unique_files: Enum.reduce(files_read, state.unique_files, &MapSet.put(&2, &1)),
        total_actions: state.total_actions + length(actions)
    }
  end

  defp finalize_trial(state, bug) do
    # If no explicit proposal, check pending proposals in memory
    {proposal_submitted, proposal_text, proposal_quality} =
      if state.proposal_submitted do
        {true, state.proposal_text, state.proposal_quality}
      else
        # Check if agent created any fix proposals in memory (exclude heartbeat types)
        case get_fix_proposals(state[:agent_id]) do
          [] ->
            {false, nil, ProposalScorer.score("", bug)}

          proposals ->
            texts = Enum.map(proposals, fn p -> Map.get(p, :content, "") end)
            score = ProposalScorer.score(texts, bug)
            {true, Enum.join(texts, "\n---\n"), score}
        end
      end

    repeated_reads =
      state.heartbeats
      |> Enum.flat_map(&extract_file_paths_from_heartbeat/1)
      |> Enum.frequencies()
      |> Enum.count(fn {_path, count} -> count > 1 end)

    %{
      heartbeats_to_proposal: if(proposal_submitted, do: state.heartbeat_count, else: nil),
      proposal_submitted: proposal_submitted,
      proposal_text: proposal_text,
      proposal_quality: proposal_quality || ProposalScorer.score("", bug),
      council_verdict: state.council_verdict,
      judge_verdict: state.judge_verdict,
      file_reads: state.file_reads,
      unique_files: MapSet.size(state.unique_files),
      repeated_reads: repeated_reads,
      total_actions: state.total_actions,
      heartbeat_count: state.heartbeat_count,
      heartbeats_data: state.heartbeats
    }
  end

  # -- Agent Lifecycle --

  defp start_eval_agent(model, provider, dot_path, directive) do
    model_config = %{
      id: model,
      provider: provider,
      runtime: :arbor,
      module: Arbor.Agent.APIAgent
    }

    opts = [
      template: "diagnostician",
      display_name: "eval-diagnostician-#{:erlang.unique_integer([:positive])}",
      heartbeat_dot: dot_path,
      system_prompt: directive,
      model: model,
      provider: provider,
      start_heartbeat: true
    ]

    Manager.start_agent(model_config, opts)
  end

  defp register_eval_zen_probes!(agent_id, model, provider) do
    ids = ProviderRoutePin.build(model, provider).probe_ids

    case OpenCodeZen.register_eval_probes(agent_id, ids) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[TaskEval] could not register zen probes: #{inspect(reason)}")
        :ok
    end
  end

  @doc false
  def wait_timeout_result(heartbeat_count)
      when is_integer(heartbeat_count) and heartbeat_count <= 0 do
    {:error, :eval_infrastructure_timeout}
  end

  def wait_timeout_result(heartbeat_count) when is_integer(heartbeat_count) do
    :finalize
  end

  @doc false
  def cleanup_eval_principal(agent_id) when is_binary(agent_id) do
    _ = OpenCodeZen.unregister_eval_probes(agent_id)
    revoke_eval_grants()
    destroy_eval_agent(agent_id)
    safe_cleanup_memory(agent_id)
    :ok
  end

  @doc false
  def worktree_fs_resources(worktree_path) when is_binary(worktree_path) do
    trimmed = worktree_path |> Path.expand() |> String.trim_leading("/")

    [
      "arbor://fs/read/#{trimmed}/**",
      "arbor://fs/list/#{trimmed}/**"
    ]
  end

  defp grant_eval_worktree_access!(agent_id, worktree_path) do
    ids =
      Enum.flat_map(worktree_fs_resources(worktree_path), fn resource ->
        case Arbor.Security.grant_capability_id(principal: agent_id, resource: resource) do
          {:ok, id} ->
            [id]

          {:error, reason} ->
            Logger.warning("[TaskEval] could not grant #{resource}: #{inspect(reason)}")
            []
        end
      end)

    Process.put(:eval_grant_ids, ids)
    :ok
  end

  defp revoke_eval_grants do
    for id <- List.wrap(Process.get(:eval_grant_ids, [])) do
      _ = Arbor.Security.revoke(id)
    end

    Process.delete(:eval_grant_ids)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp relax_eval_trust!(agent_id) do
    case Arbor.Trust.get_trust_profile(agent_id) do
      {:ok, profile} ->
        rules =
          Map.put(
            profile.rules || %{},
            "arbor://action/session_goals/prune_stale_intents",
            :auto
          )

        case Arbor.Trust.ensure_trust_profile(agent_id, baseline: :allow, rules: rules) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("[TaskEval] could not relax eval trust: #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("[TaskEval] no trust profile to relax: #{inspect(reason)}")
        :ok
    end
  end

  defp seed_bug_goal(agent_id, bug) do
    safe_call(fn ->
      goal =
        Arbor.Contracts.Memory.Goal.new(bug.initial_goal,
          priority: 90,
          success_criteria: "Submit a proposal identifying the root cause and fix"
        )

      Arbor.Memory.add_goal(agent_id, goal)
    end)
  end

  defp build_directive(bug, worktree_path) do
    String.replace(bug.directive_template, "{WORKTREE_PATH}", worktree_path)
  end

  # -- DOT Path Resolution --

  defp resolve_dot_path(variant) do
    filename = Map.fetch!(@variant_dots, variant)
    # The SessionManager will resolve the full path — we just set the app env
    # so it picks up the right file. But we also return the full path for
    # the heartbeat_dot opt.
    find_dot_file(filename)
  end

  defp find_dot_file(filename) do
    cwd = File.cwd!()

    candidates = [
      Path.join([cwd, "apps", "arbor_orchestrator", "specs", "pipelines", "session", filename]),
      Path.join([cwd, "..", "arbor_orchestrator", "specs", "pipelines", "session", filename])
      |> Path.expand(),
      Path.join([cwd, "specs", "pipelines", "session", filename])
    ]

    Enum.find(candidates, List.first(candidates), &File.exists?/1)
  end

  # -- Worktree Management --

  @doc false
  def create_worktree(bug) do
    worktree_path = worktree_dir(bug)

    # Clean up any stale worktree first
    cleanup_worktree(bug)

    case System.cmd("git", ["worktree", "add", "--detach", worktree_path, bug.pre_fix_commit],
           cd: project_root(),
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("[TaskEval] Created worktree at #{worktree_path}")
        {:ok, worktree_path}

      {output, code} ->
        {:error, {:worktree_failed, code, output}}
    end
  end

  @doc false
  def cleanup_worktree(bug) do
    worktree_path = worktree_dir(bug)

    if File.dir?(worktree_path) do
      System.cmd("git", ["worktree", "remove", "--force", worktree_path],
        cd: project_root(),
        stderr_to_stdout: true
      )
    end

    :ok
  end

  defp worktree_dir(bug) do
    Path.join([System.tmp_dir!(), "arbor_eval", "worktree_#{bug.id}"])
  end

  defp project_root do
    cwd = File.cwd!()

    cond do
      File.exists?(Path.join(cwd, "apps")) ->
        cwd

      File.exists?(Path.join([cwd, "..", "apps"]) |> Path.expand()) ->
        Path.expand(Path.join([cwd, ".."]))

      true ->
        cwd
    end
  end

  # -- Proposal Detection --

  @doc false
  def proposal_submitted?(agent_id, hb_data) do
    # Authored submissions live in heartbeat JSON `proposals: [%{kind, content}]`
    # (legacy: `fix_proposal` string). Do NOT treat :thought/:goal/etc. as a
    # bug-fix submission — those fire every cycle.
    present_text?(authored_fix_text(hb_data)) or
      Enum.any?(extract_actions(hb_data), &proposal_action?/1) or
      get_fix_proposals(agent_id) != []
  end

  defp extract_proposal_text(agent_id, hb_data) do
    cond do
      present_text?(authored_fix_text(hb_data)) ->
        authored_fix_text(hb_data)

      true ->
        case get_fix_proposals(agent_id) do
          [proposal | _] ->
            Map.get(proposal, :content, "")

          [] ->
            Map.get(hb_data, :agent_thinking, "") ||
              Map.get(hb_data, "agent_thinking", "")
        end
    end
  end

  @eval_fix_kinds ~w(fix bug_fix fix_proposal)

  defp authored_fix_text(hb_data) when is_map(hb_data) do
    from_list =
      hb_data
      |> Map.get(:proposals, Map.get(hb_data, "proposals", []))
      |> List.wrap()
      |> Enum.find_value(fn item ->
        kind = to_string(Map.get(item, :kind) || Map.get(item, "kind") || "")
        content = Map.get(item, :content) || Map.get(item, "content")

        if kind in @eval_fix_kinds and present_text?(content), do: content
      end)

    from_list || hb_data[:fix_proposal] || hb_data["fix_proposal"]
  end

  defp authored_fix_text(_), do: nil

  defp present_text?(text) when is_binary(text), do: String.trim(text) != ""
  defp present_text?(_), do: false

  defp get_pending_proposals(nil), do: []

  defp get_pending_proposals(agent_id) do
    case safe_call(fn -> Arbor.Memory.Proposal.list_pending(agent_id) end) do
      {:ok, proposals} -> proposals
      _ -> []
    end
  end

  # Authored eval submissions persist as Memory.Proposal type :insight with
  # metadata.kind in @eval_fix_kinds. Generic :insight/:learning from
  # InsightDetector must not count as a bug-fix delivery.
  defp get_fix_proposals(agent_id) do
    agent_id
    |> get_pending_proposals()
    |> Enum.filter(&authored_eval_fix?/1)
  end

  defp authored_eval_fix?(proposal) when is_map(proposal) do
    type = Map.get(proposal, :type)
    kind = proposal |> Map.get(:metadata, %{}) |> then(&(&1[:kind] || &1["kind"]))
    type == :insight and to_string(kind || "") in @eval_fix_kinds
  end

  defp authored_eval_fix?(_), do: false

  # -- Action Helpers --

  defp extract_actions(hb_data) do
    # Signal data can have atom or string keys
    raw =
      Map.get(hb_data, :actions, nil) ||
        Map.get(hb_data, "actions", nil) ||
        []

    List.wrap(raw)
  end

  defp file_read_action?(action) when is_map(action) do
    name = Map.get(action, :name) || Map.get(action, "name") || ""
    type = Map.get(action, :type) || Map.get(action, "type") || ""
    id = to_string(name) <> " " <> to_string(type)

    String.contains?(id, "file_read") or
      String.contains?(id, "file.read")
  end

  defp file_read_action?(_), do: false

  defp proposal_action?(action) when is_map(action) do
    name = Map.get(action, :name) || Map.get(action, "name") || ""
    type = Map.get(action, :type) || Map.get(action, "type") || ""
    id = to_string(name) <> " " <> to_string(type)

    String.contains?(id, "proposal") or
      String.contains?(id, "submit")
  end

  defp proposal_action?(_), do: false

  defp extract_file_path(action) when is_map(action) do
    params = Map.get(action, :params) || Map.get(action, "params") || %{}
    Map.get(params, :path) || Map.get(params, "path") || "unknown"
  end

  defp extract_file_path(_), do: "unknown"

  defp extract_file_paths_from_heartbeat(hb_data) do
    hb_data
    |> extract_actions()
    |> Enum.filter(&file_read_action?/1)
    |> Enum.map(&extract_file_path/1)
  end

  # -- Persistence --

  defp persist_trial(trial, variant, rep, tag, opts) do
    model = Keyword.get(opts, :model, @default_model)
    provider = Keyword.get(opts, :provider, @default_provider)

    run_id =
      "task_#{variant}_r#{rep}_#{:erlang.unique_integer([:positive])}"

    run_attrs = %{
      id: run_id,
      domain: "task_eval",
      model: model,
      provider: to_string(provider),
      dataset: "#{variant}_bug_#{trial[:bug_id] || "glob_wildcard"}",
      graders: ["proposal_scorer"],
      sample_count: trial.heartbeat_count,
      duration_ms: trial[:duration_ms] || 0,
      metrics: serialize_metrics(trial),
      config: %{
        "variant" => to_string(variant),
        "max_heartbeats" => Keyword.get(opts, :max_heartbeats, @default_max_heartbeats),
        "model" => model,
        "provider" => to_string(provider),
        "context_management" => to_string(Keyword.get(opts, :context_management, :none))
      },
      metadata: if(tag, do: %{"tag" => tag}, else: %{}),
      status: "completed"
    }

    persist_run(run_attrs)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp serialize_metrics(trial) do
    %{
      "heartbeats_to_proposal" => trial[:heartbeats_to_proposal],
      "proposal_submitted" => trial.proposal_submitted,
      "proposal_quality" => serialize_score(trial.proposal_quality),
      "file_reads" => trial.file_reads,
      "unique_files" => trial.unique_files,
      "repeated_reads" => trial.repeated_reads,
      "total_actions" => trial.total_actions,
      "heartbeat_count" => trial.heartbeat_count
    }
  end

  defp serialize_score(nil), do: nil

  defp serialize_score(score) when is_map(score) do
    Map.new(score, fn {k, v} -> {to_string(k), v} end)
  end

  defp persist_run(attrs) do
    Arbor.Persistence.insert_eval_run(attrs)
  rescue
    _ -> {:error, :persistence_error}
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end

  # -- Summary --

  defp build_summary(results, variants) do
    successful = Enum.reject(results, &Map.has_key?(&1, :error))
    by_variant = Enum.group_by(successful, & &1.variant)

    %{
      variants:
        Map.new(variants, fn v ->
          trials = Map.get(by_variant, v, [])

          stats = %{
            trial_count: length(trials),
            proposals_submitted: Enum.count(trials, & &1.proposal_submitted),
            avg_heartbeats:
              if(trials != [],
                do:
                  trials
                  |> Enum.map(& &1.heartbeat_count)
                  |> then(&(Enum.sum(&1) / length(&1)))
                  |> Float.round(1),
                else: 0
              ),
            avg_quality:
              if(trials != [],
                do:
                  trials
                  |> Enum.map(&get_in(&1, [:proposal_quality, :overall]))
                  |> Enum.reject(&is_nil/1)
                  |> then(fn
                    [] -> 0.0
                    scores -> Float.round(Enum.sum(scores) / length(scores), 3)
                  end),
                else: 0.0
              ),
            avg_file_reads:
              if(trials != [],
                do: Float.round(Enum.sum(Enum.map(trials, & &1.file_reads)) / length(trials), 1),
                else: 0
              ),
            avg_unique_files:
              if(trials != [],
                do:
                  Float.round(Enum.sum(Enum.map(trials, & &1.unique_files)) / length(trials), 1),
                else: 0
              ),
            avg_repeated_reads:
              if(trials != [],
                do:
                  Float.round(
                    Enum.sum(Enum.map(trials, & &1.repeated_reads)) / length(trials),
                    1
                  ),
                else: 0
              )
          }

          {v, stats}
        end),
      total_trials: length(results),
      successful_trials: length(successful),
      failed_trials: length(results) - length(successful)
    }
  end

  # -- Safe Wrappers --

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp destroy_eval_agent(agent_id) do
    Lifecycle.destroy(agent_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_cleanup_memory(agent_id) do
    safe_call(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)

    for table <- [
          :arbor_memory_goals,
          :arbor_working_memory,
          :arbor_memory_proposals,
          :arbor_chat_history,
          :arbor_memory_thinking,
          :arbor_memory_intents
        ] do
      safe_call(fn ->
        if :ets.whereis(table) != :undefined do
          :ets.match_delete(table, {{agent_id, :_}, :_})
        end
      end)
    end
  end
end
