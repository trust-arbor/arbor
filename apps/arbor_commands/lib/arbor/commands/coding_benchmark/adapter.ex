defmodule Arbor.Commands.CodingBenchmark.Adapter do
  @moduledoc false

  alias Arbor.Commands.CodingBenchmark.{ApprovalObservations, Git, Runtime}
  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Shell

  @app :arbor_commands
  @principal_key :coding_benchmark_principal_id
  @request_schema "arbor.coding_benchmark.adapter_request.v1"
  @request_keys MapSet.new(~w(
    acp_agent base_commit_oid base_tree_oid executor_path fixture_id normalized_input
    normalized_input_hash repetition schema seed workdir
  ))
  @input_keys MapSet.new(~w(acceptance_criteria objective))
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @hash_pattern ~r/\A[0-9a-f]{64}\z/
  @id_pattern ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @max_counter 10_000
  # Module-owned slice kept below the outer harness Task.yield deadline so graph
  # expiry can settle and cancel without racing the outer bound. Not config-
  # or manifest-overridable. Matches Plan's public 10s–24h wall-clock bounds.
  @pipeline_budget_reserve_ms 5_000
  @plan_min_wall_clock_ms 10_000
  @plan_max_wall_clock_ms 86_400_000

  @spec run(map(), String.t(), function(), atom()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(request, executor_path, default_runner, executor_config_key)
      when is_function(default_runner, 3) do
    with {:ok, request} <- validate_request(request, executor_path),
         {:ok, runtime} <- Runtime.load(),
         :ok <- Runtime.preflight_production(runtime),
         {:ok, scope} <- execution_scope(request, runtime),
         request = Map.put(request, "workdir", scope.workdir),
         :ok <-
           matching_base(
             request["workdir"],
             request["base_commit_oid"],
             request["base_tree_oid"],
             runtime.execution_timeout_ms
           ),
         {:ok, principal_id} <- configured_principal_id(),
         {:ok, executor} <- configured_executor(executor_config_key, default_runner),
         {:ok, task, context} <- execution_inputs(request, scope, runtime.execution_timeout_ms),
         returned <- invoke_executor(executor, default_runner, principal_id, task, context) do
      normalize_return(returned, scope.task_id)
    end
  end

  @spec execution_scope(map(), Runtime.config()) ::
          {:ok, map()} | {:error, {:benchmark_setup_error, term()}}
  def execution_scope(request, runtime) when is_map(request) do
    digest = execution_digest(request)
    task_id = task_id(request, digest)

    with {:ok, topology} <-
           Runtime.prepare_execution(
             request["workdir"],
             request["executor_path"],
             digest,
             task_id,
             runtime
           ) do
      {:ok,
       Map.merge(topology, %{
         branch_name: branch_name(request, digest),
         task_id: task_id
       })}
    end
  end

  @spec verification_scope(map(), Runtime.config()) ::
          {:ok, map()} | {:error, {:benchmark_setup_error, term()}}
  def verification_scope(request, runtime) when is_map(request) do
    digest = execution_digest(request)
    task_id = task_id(request, digest)

    with {:ok, topology} <-
           Runtime.preview_execution(
             request["workdir"],
             request["executor_path"],
             digest,
             task_id,
             runtime
           ) do
      {:ok,
       Map.merge(topology, %{
         branch_name: branch_name(request, digest),
         task_id: task_id
       })}
    end
  end

  @spec cancel(map(), String.t(), function(), atom(), :unsupported | function()) ::
          :ok | {:ok, term()} | {:error, term()}
  def cancel(request, executor_path, default_runner, executor_config_key, default_cancel)
      when is_function(default_runner, 3) do
    with {:ok, request} <- validate_request(request, executor_path),
         {:ok, runtime} <- Runtime.load(),
         :ok <- Runtime.preflight_production(runtime),
         {:ok, scope} <- verification_scope(request, runtime),
         {:ok, principal_id} <- configured_principal_id(),
         {:ok, executor} <- configured_executor(executor_config_key, default_runner) do
      invoke_cancel(
        executor,
        default_runner,
        default_cancel,
        principal_id,
        %{"task_id" => scope.task_id}
      )
    end
  end

  defp validate_request(request, executor_path)
       when is_map(request) and not is_struct(request) do
    with :ok <- exact_keys(request, @request_keys),
         :ok <- exact(request["schema"], @request_schema, :invalid_request_schema),
         :ok <- exact(request["executor_path"], executor_path, :executor_path_mismatch),
         :ok <- valid_id(request["fixture_id"]),
         :ok <- valid_oid(request["base_commit_oid"], :invalid_base_commit_oid),
         :ok <- valid_oid(request["base_tree_oid"], :invalid_base_tree_oid),
         :ok <- valid_hash(request["normalized_input_hash"]),
         :ok <- valid_integer(request["repetition"], 1, 100, :invalid_repetition),
         :ok <- valid_integer(request["seed"], 0, 2_147_483_647, :invalid_seed),
         :ok <- valid_nonblank(request["acp_agent"], :invalid_acp_agent),
         :ok <- valid_input(request["normalized_input"]),
         :ok <- matching_input_hash(request),
         :ok <- valid_nonblank(request["workdir"], :invalid_benchmark_workdir) do
      {:ok, request}
    end
  end

  defp validate_request(_request, _executor_path), do: {:error, :invalid_benchmark_request}

  defp exact_keys(map, expected) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) -> {:error, :non_string_request_key}
      MapSet.new(keys) != expected -> {:error, :invalid_benchmark_request_keys}
      true -> :ok
    end
  end

  defp exact(value, value, _reason), do: :ok
  defp exact(_actual, _expected, reason), do: {:error, reason}

  defp valid_id(value) when is_binary(value) do
    if Regex.match?(@id_pattern, value), do: :ok, else: {:error, :invalid_fixture_id}
  end

  defp valid_id(_value), do: {:error, :invalid_fixture_id}

  defp valid_oid(value, reason) when is_binary(value) do
    if Regex.match?(@oid_pattern, value), do: :ok, else: {:error, reason}
  end

  defp valid_oid(_value, reason), do: {:error, reason}

  defp valid_hash(value) when is_binary(value) do
    if Regex.match?(@hash_pattern, value),
      do: :ok,
      else: {:error, :invalid_normalized_input_hash}
  end

  defp valid_hash(_value), do: {:error, :invalid_normalized_input_hash}

  defp valid_integer(value, min, max, _reason)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp valid_integer(_value, _min, _max, reason), do: {:error, reason}

  defp valid_nonblank(value, reason) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "" and
         not String.contains?(value, <<0>>),
       do: :ok,
       else: {:error, reason}
  end

  defp valid_nonblank(_value, reason), do: {:error, reason}

  defp valid_input(input) when is_map(input) and not is_struct(input) do
    with :ok <- exact_keys(input, @input_keys),
         :ok <- valid_nonblank(input["objective"], :invalid_objective) do
      valid_criteria(input["acceptance_criteria"])
    end
  end

  defp valid_input(_input), do: {:error, :invalid_normalized_input}

  defp valid_criteria(criteria) when is_list(criteria) and length(criteria) <= 100 do
    if Enum.all?(criteria, &(valid_nonblank(&1, :invalid_acceptance_criterion) == :ok)),
      do: :ok,
      else: {:error, :invalid_acceptance_criteria}
  end

  defp valid_criteria(_criteria), do: {:error, :invalid_acceptance_criteria}

  defp matching_input_hash(request) do
    if hash_json(request["normalized_input"]) == request["normalized_input_hash"],
      do: :ok,
      else: {:error, :normalized_input_hash_mismatch}
  end

  defp matching_base(workdir, commit_oid, tree_oid, timeout_ms) do
    with {:ok, ^workdir} <- git_output(workdir, ["rev-parse", "--show-toplevel"], timeout_ms),
         {:ok, ^commit_oid} <-
           git_output(workdir, ["rev-parse", "--verify", "#{commit_oid}^{commit}"], timeout_ms),
         {:ok, ^tree_oid} <-
           git_output(workdir, ["rev-parse", "--verify", "#{commit_oid}^{tree}"], timeout_ms) do
      :ok
    else
      _other -> {:error, :benchmark_base_mismatch}
    end
  end

  defp configured_principal_id do
    case Application.fetch_env(@app, @principal_key) do
      {:ok, principal_id} ->
        case valid_nonblank(principal_id, :invalid_benchmark_principal_id) do
          :ok -> {:ok, String.trim(principal_id)}
          {:error, _reason} -> {:error, :invalid_benchmark_principal_id}
        end

      :error ->
        {:error, :benchmark_principal_id_not_configured}
    end
  end

  defp configured_executor(config_key, default_runner) do
    case Application.fetch_env(@app, config_key) do
      :error ->
        {:ok, {:default, default_runner}}

      {:ok, executor} when is_atom(executor) ->
        if Code.ensure_loaded?(executor) and function_exported?(executor, :run, 3),
          do: {:ok, {:module, executor}},
          else: {:error, {:invalid_benchmark_executor_module, config_key}}

      {:ok, _invalid} ->
        {:error, {:invalid_benchmark_executor_module, config_key}}
    end
  end

  @doc false
  @spec pipeline_budget_reserve_ms() :: pos_integer()
  def pipeline_budget_reserve_ms, do: @pipeline_budget_reserve_ms

  @doc false
  @spec plan_min_wall_clock_ms() :: pos_integer()
  def plan_min_wall_clock_ms, do: @plan_min_wall_clock_ms

  defp execution_inputs(request, scope, execution_timeout_ms) do
    context = %{
      "task_id" => scope.task_id,
      "timeout" => execution_timeout_ms
    }

    case request["executor_path"] do
      "legacy" ->
        with {:ok, validation_timeout_ms} <-
               legacy_validation_timeout_ms(execution_timeout_ms) do
          {:ok, legacy_flat_task(request, scope, validation_timeout_ms), context}
        end

      "pipeline" ->
        with {:ok, wall_clock_ms} <- pipeline_wall_clock_ms(execution_timeout_ms),
             {:ok, task} <- pipeline_plan_task(request, scope, wall_clock_ms) do
          {:ok, task, context}
        end
    end
  end

  # Per-validation budget for the legacy ProduceReviewableChange path. Bounded by
  # the trusted harness execution timeout and the reviewed standard spawn-capable
  # Shell ceiling so cold compile cannot sit at the action's 300s default while
  # the pipeline path correctly uses the Shell-derived 600s profile ceiling.
  # Data only — never control authority.
  defp legacy_validation_timeout_ms(execution_timeout_ms)
       when is_integer(execution_timeout_ms) and execution_timeout_ms > 0 do
    ceiling = Shell.spawn_capable_max_timeout_ms()
    {:ok, min(execution_timeout_ms, ceiling)}
  end

  defp legacy_validation_timeout_ms(_execution_timeout_ms),
    do: setup_error(:invalid_legacy_validation_timeout_budget)

  defp legacy_flat_task(request, scope, validation_timeout_ms) do
    %{
      "acp_agent" => request["acp_agent"],
      "base_ref" => request["base_commit_oid"],
      "branch_name" => scope.branch_name,
      "kind" => "coding_change",
      "open_pr" => false,
      "repo_path" => request["workdir"],
      "submit_review" => true,
      "task" => task_text(request["normalized_input"]),
      "validation_timeout" => validation_timeout_ms,
      "worktree_base_dir" => scope.worktree_root
    }
  end

  # Graph wall budget is derived only from the trusted runtime execution
  # timeout. Manifest/task/worker data must never select or widen it.
  defp pipeline_wall_clock_ms(outer_timeout_ms)
       when is_integer(outer_timeout_ms) and outer_timeout_ms > 0 do
    wall_clock_ms = outer_timeout_ms - @pipeline_budget_reserve_ms

    cond do
      wall_clock_ms < @plan_min_wall_clock_ms ->
        setup_error(:pipeline_budget_timeout_insufficient)

      wall_clock_ms > @plan_max_wall_clock_ms ->
        setup_error(:pipeline_budget_timeout_insufficient)

      true ->
        {:ok, wall_clock_ms}
    end
  end

  defp pipeline_wall_clock_ms(_outer_timeout_ms),
    do: setup_error(:pipeline_budget_timeout_insufficient)

  defp pipeline_plan_task(request, scope, wall_clock_ms) do
    plan_attrs = %{
      "version" => Plan.schema_version(),
      "task" => task_text(request["normalized_input"]),
      "repo_root" => request["workdir"],
      "base_ref" => request["base_commit_oid"],
      "workspace_policy" => %{
        "mode" => "isolated",
        "branch_name" => scope.branch_name,
        "worktree_base_dir" => scope.worktree_root
      },
      "worker" => %{"provider" => request["acp_agent"]},
      "review_profile" => "binding",
      "budgets" => %{"wall_clock_ms" => wall_clock_ms},
      "output" => %{"draft_pr" => false}
    }

    case Plan.new(plan_attrs) do
      {:ok, plan} ->
        canonical = Plan.to_map(plan)

        if canonical["budgets"]["wall_clock_ms"] == wall_clock_ms do
          {:ok, %{"kind" => "coding_change", "plan" => canonical}}
        else
          setup_error(:pipeline_budget_mismatch)
        end

      {:error, reason} ->
        setup_error({:invalid_pipeline_plan, reason})
    end
  end

  defp setup_error(reason), do: {:error, {:benchmark_setup_error, reason}}

  defp execution_digest(request) do
    hash_json(%{
      "base_commit_oid" => request["base_commit_oid"],
      "executor_path" => request["executor_path"],
      "fixture_id" => request["fixture_id"],
      "normalized_input_hash" => request["normalized_input_hash"],
      "repetition" => request["repetition"],
      "seed" => request["seed"]
    })
  end

  defp task_id(request, digest) do
    "coding-benchmark-#{request["executor_path"]}-#{digest}"
  end

  defp branch_name(request, digest) do
    "arbor/coding-benchmark/#{request["fixture_id"]}-r#{request["repetition"]}-#{request["executor_path"]}-#{String.slice(digest, 0, 12)}"
  end

  defp task_text(%{"objective" => objective, "acceptance_criteria" => []}), do: objective

  defp task_text(%{"objective" => objective, "acceptance_criteria" => criteria}) do
    objective <> "\n\nAcceptance criteria:\n" <> Enum.map_join(criteria, "\n", &"- #{&1}")
  end

  defp invoke_executor({:default, runner}, _default_runner, principal_id, task, context),
    do: runner.(principal_id, task, context)

  defp invoke_executor({:module, executor}, _default_runner, principal_id, task, context),
    do: executor.run(principal_id, task, context)

  defp invoke_cancel({:default, _runner}, _default_runner, default_cancel, principal_id, context)
       when is_function(default_cancel, 2),
       do: default_cancel.(principal_id, context)

  defp invoke_cancel(
         {:default, _runner},
         _default_runner,
         _default_cancel,
         _principal_id,
         _context
       ),
       do: {:error, :cancellation_unsupported}

  defp invoke_cancel({:module, executor}, _default_runner, _default_cancel, principal_id, context) do
    cond do
      function_exported?(executor, :cancel_task, 2) ->
        executor.cancel_task(principal_id, context)

      true ->
        {:error, :cancellation_unsupported}
    end
  end

  defp normalize_return({:ok, :pending_approval, approval_id}, task_id)
       when is_binary(approval_id) do
    pending_approval(approval_id, task_id)
  end

  defp normalize_return({:error, {:pending_approval, approval_id}}, task_id)
       when is_binary(approval_id) do
    pending_approval(approval_id, task_id)
  end

  defp normalize_return({:ok, result}, task_id) when is_map(result) and not is_struct(result) do
    result = normalize_success_result(result)

    {:ok,
     %{
       "counters" => result_counters(result),
       "observations" => result_observations(result, task_id),
       "result" => result,
       "worker_ownership" => result_worker_ownership(result)
     }}
  end

  defp normalize_return({:error, reason}, _task_id) do
    {:error, reason, empty_envelope()}
  end

  defp normalize_return(other, _task_id) do
    {:error, {:unexpected_benchmark_executor_return, other}, empty_envelope()}
  end

  defp pending_approval(approval_id, task_id) do
    approval =
      case correlated_approval_observations(task_id) do
        {:ok, observations} ->
          observations
          |> Map.put("status", "pending")
          |> Map.put("resumed", false)

        :unavailable ->
          %{
            "count" => 1,
            "requested" => true,
            "required" => true,
            "resumed" => false,
            "status" => "pending"
          }
      end

    envelope = put_in(empty_envelope(), ["observations", "approval"], approval)

    {:error, {:pending_approval, approval_id}, envelope}
  end

  defp empty_envelope do
    %{
      "counters" => %{"rework_cycles" => 0, "validation_cycles" => 0},
      "observations" => %{},
      "worker_ownership" => "unknown"
    }
  end

  defp normalize_success_result(result) do
    case map_value(result, "result_type", :result_type) do
      nil -> %{"payload" => result, "raw" => result, "result_type" => "coding_change"}
      _type -> result
    end
  end

  defp result_counters(result) do
    metrics = result_metrics(result)

    %{
      "rework_cycles" =>
        bounded_counter(map_value(metrics, "total_rework_count", :total_rework_count)),
      "validation_cycles" =>
        bounded_counter(map_value(metrics, "validation_attempts", :validation_attempts))
    }
  end

  defp bounded_counter(value) when is_integer(value) and value in 0..@max_counter, do: value
  defp bounded_counter(_value), do: 0

  defp result_observations(result, task_id) do
    status = result_status(result)
    metrics = result_metrics(result)

    approval =
      case correlated_approval_observations(task_id) do
        {:ok, observations} -> observations
        :unavailable -> terminal_approval_inference(result, status)
      end

    cancellation =
      if status == "cancelled" do
        %{"cancelled" => true, "requested" => true, "status" => "cancelled"}
      else
        %{"cancelled" => false, "requested" => false, "status" => "not_requested"}
      end

    cleanup_status =
      metrics
      |> map_value("workspace_release_status", :workspace_release_status)
      |> normalized_token("unobserved")

    %{
      "approval" => approval,
      "cancellation" => cancellation,
      "cleanup" => %{"status" => cleanup_status}
    }
  end

  # Prefer interaction audit signals correlated to this exact task_id. Fallback
  # to terminal approval_request_id inference when history is unavailable.
  defp correlated_approval_observations(task_id)
       when is_binary(task_id) and task_id != "" do
    if Arbor.Signals.healthy?() do
      case Arbor.Signals.query(
             category: :interaction,
             correlation_id: task_id,
             limit: 1_000
           ) do
        {:ok, signals} when is_list(signals) ->
          case ApprovalObservations.from_signals(signals) do
            :empty -> :unavailable
            observations when is_map(observations) -> {:ok, observations}
          end

        _other ->
          :unavailable
      end
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp correlated_approval_observations(_task_id), do: :unavailable

  defp terminal_approval_inference(result, status) do
    approval_id = first_value(result_sources(result), "approval_request_id", :approval_request_id)

    cond do
      status == "approval_denied" ->
        %{
          "count" => 1,
          "requested" => true,
          "required" => true,
          "resumed" => false,
          "status" => "denied"
        }

      is_binary(approval_id) and approval_id != "" ->
        %{
          "count" => 1,
          "requested" => true,
          "required" => true,
          "resumed" => true,
          "status" => "approved"
        }

      true ->
        %{
          "count" => 0,
          "requested" => false,
          "required" => false,
          "resumed" => false,
          "status" => "not_required"
        }
    end
  end

  defp result_worker_ownership(result) do
    result
    |> result_metrics()
    |> map_value("worker_ownership", :worker_ownership)
    |> normalized_token("unknown")
    |> case do
      value when value in ~w(owned reused none unknown) -> value
      _other -> "unknown"
    end
  end

  defp result_status(result) do
    first_value(result_sources(result), "canonical_status", :canonical_status) ||
      first_value(result_sources(result), "status", :status)
  end

  defp result_metrics(result) do
    first_value(result_sources(result), "metrics", :metrics)
    |> case do
      metrics when is_map(metrics) and not is_struct(metrics) -> metrics
      _other -> %{}
    end
  end

  defp result_sources(result) do
    payload = map_value(result, "payload", :payload)
    report = map_value(payload, "report", :report)
    raw = map_value(result, "raw", :raw)
    Enum.filter([report, payload, raw, result], &is_map/1)
  end

  defp first_value(sources, string_key, atom_key) do
    Enum.find_value(sources, fn source -> map_value(source, string_key, atom_key) end)
  end

  defp map_value(map, string_key, atom_key) when is_map(map) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp map_value(_map, _string_key, _atom_key), do: nil

  # nil is an atom in Elixir; project the supplied default rather than "nil".
  defp normalized_token(nil, default), do: default

  defp normalized_token(value, _default) when is_atom(value), do: Atom.to_string(value)

  defp normalized_token(value, default) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "", do: value, else: default
  end

  defp normalized_token(_value, default), do: default

  defp git_output(workdir, args, timeout_ms) do
    case Git.run(workdir, args, timeout_ms) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} -> {:error, :git_failed}
    end
  end

  defp hash_json(value), do: value |> canonical_json() |> IO.iodata_to_binary() |> sha256()

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(value) when is_binary(value), do: Jason.encode_to_iodata!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)

  defp canonical_json(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode_to_iodata!(key), ":", canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end
end
