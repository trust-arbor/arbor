defmodule Arbor.Commands.CodingBenchmark.Adapter do
  @moduledoc false

  alias Arbor.Common.SafePath

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

  @spec run(map(), String.t(), module(), atom()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(request, executor_path, default_executor, executor_config_key) do
    with {:ok, request} <- validate_request(request, executor_path),
         {:ok, principal_id} <- configured_principal_id(),
         {:ok, executor} <- configured_executor(executor_config_key, default_executor),
         {:ok, task, context} <- execution_inputs(request),
         returned <- executor.run(principal_id, task, context) do
      normalize_return(returned)
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
         {:ok, workdir} <- canonical_repo(request["workdir"]),
         :ok <- matching_base(workdir, request["base_commit_oid"], request["base_tree_oid"]) do
      {:ok, Map.put(request, "workdir", workdir)}
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

  defp canonical_repo(path) when is_binary(path) do
    with :ok <- SafePath.validate(path),
         {:ok, real} <- SafePath.resolve_real(path),
         true <- File.dir?(real),
         {:ok, ^real} <- git_output(real, ["rev-parse", "--show-toplevel"]) do
      {:ok, real}
    else
      _other -> {:error, :invalid_benchmark_workdir}
    end
  end

  defp canonical_repo(_path), do: {:error, :invalid_benchmark_workdir}

  defp matching_base(workdir, commit_oid, tree_oid) do
    with {:ok, ^commit_oid} <-
           git_output(workdir, ["rev-parse", "--verify", "#{commit_oid}^{commit}"]),
         {:ok, ^tree_oid} <-
           git_output(workdir, ["rev-parse", "--verify", "#{commit_oid}^{tree}"]) do
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

  defp configured_executor(config_key, default_executor) do
    executor = Application.get_env(@app, config_key, default_executor)

    if is_atom(executor) and Code.ensure_loaded?(executor) and
         function_exported?(executor, :run, 3) do
      {:ok, executor}
    else
      {:error, {:invalid_benchmark_executor_module, config_key}}
    end
  end

  defp execution_inputs(request) do
    digest = execution_digest(request)
    workdir = request["workdir"]

    with {:ok, worktree_base} <- prepare_worktree_base(workdir, request["executor_path"], digest) do
      task = %{
        "acp_agent" => request["acp_agent"],
        "base_ref" => request["base_commit_oid"],
        "branch_name" => branch_name(request, digest),
        "kind" => "coding_change",
        "open_pr" => false,
        "repo_path" => workdir,
        "submit_review" => true,
        "task" => task_text(request["normalized_input"]),
        "worktree_base_dir" => worktree_base
      }

      context = %{"task_id" => task_id(request, digest)}
      {:ok, task, context}
    end
  end

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

  defp prepare_worktree_base(workdir, executor_path, digest) do
    components = [".arbor-coding-benchmark", executor_path, digest]

    with {:ok, path} <- create_directories(workdir, components),
         {:ok, real} <- SafePath.resolve_real(path),
         {:ok, ^real} <- SafePath.resolve_within(real, workdir) do
      {:ok, real}
    else
      _other -> {:error, :invalid_benchmark_worktree_base}
    end
  end

  defp create_directories(root, components) do
    Enum.reduce_while(components, {:ok, root}, fn component, {:ok, parent} ->
      child = Path.join(parent, component)

      case ensure_directory(child) do
        :ok -> {:cont, {:ok, child}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_worktree_base_component}
      {:error, :enoent} -> File.mkdir(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_return({:ok, :pending_approval, approval_id}) when is_binary(approval_id) do
    pending_approval(approval_id)
  end

  defp normalize_return({:error, {:pending_approval, approval_id}})
       when is_binary(approval_id) do
    pending_approval(approval_id)
  end

  defp normalize_return({:ok, result}) when is_map(result) and not is_struct(result) do
    result = normalize_success_result(result)

    {:ok,
     %{
       "counters" => result_counters(result),
       "observations" => result_observations(result),
       "result" => result,
       "worker_ownership" => result_worker_ownership(result)
     }}
  end

  defp normalize_return({:error, reason}) do
    {:error, reason, empty_envelope()}
  end

  defp normalize_return(other) do
    {:error, {:unexpected_benchmark_executor_return, other}, empty_envelope()}
  end

  defp pending_approval(approval_id) do
    envelope =
      empty_envelope()
      |> put_in(["observations", "approval"], %{
        "count" => 1,
        "requested" => true,
        "required" => true,
        "resumed" => false,
        "status" => "pending"
      })

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

  defp result_observations(result) do
    status = result_status(result)
    metrics = result_metrics(result)
    approval_id = first_value(result_sources(result), "approval_request_id", :approval_request_id)

    approval =
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

  defp normalized_token(value, _default) when is_atom(value), do: Atom.to_string(value)

  defp normalized_token(value, default) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "", do: value, else: default
  end

  defp normalized_token(_value, default), do: default

  defp git_output(workdir, args) do
    # Fixed executable and argument vector; no shell interpolation occurs.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :git_failed}
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
