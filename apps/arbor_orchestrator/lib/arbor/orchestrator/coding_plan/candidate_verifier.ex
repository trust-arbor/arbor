defmodule Arbor.Orchestrator.CodingPlan.CandidateVerifier do
  @moduledoc false

  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.CodingPlan.{CandidateVerificationCore, ValidationProgram}
  alias Arbor.Orchestrator.Config

  @inspect_action "coding_workspace_inspect"
  @max_id_bytes 256
  @max_path_bytes 4_096
  @allowed_option_keys [:agent_id, :caller_id, :signing_authority, :task_id]

  @type verification_error ::
          :candidate_verification_failed
          | :candidate_verification_unavailable
          | :invalid_agent_id
          | :invalid_caller_id
          | :invalid_candidate
          | :invalid_options
          | :invalid_review_attestation_id
          | :invalid_signing_authority
          | :invalid_task_id
          | :invalid_workspace_id
          | :review_attestation_forbidden
          | :review_attestation_required
          | :signing_authority_principal_mismatch
          | :validator_execution_failed
          | :workspace_inspection_failed

  @doc false
  @spec verify(term(), term()) :: {:ok, map()} | {:error, verification_error()}
  def verify(candidate, opts) do
    with {:ok, candidate} <- normalize_candidate(candidate),
         {:ok, auth} <- normalize_options(opts),
         {:ok, inspect_workdir} <- inspection_workdir(),
         {:ok, executor} <- actions_executor(),
         approval_timeout_ms =
           Config.coding_approval_timeout_ms(candidate.program["static_parameters"]["timeout"]),
         executor_opts = executor_opts(auth, approval_timeout_ms),
         {:ok, inspection} <-
           execute(
             executor,
             @inspect_action,
             %{
               "workspace_id" => candidate.workspace_id,
               "include_committable_tree" => true
             },
             inspect_workdir,
             executor_opts,
             :workspace_inspection_failed
           ),
         {:ok, observed_tree_oid, tree_observed_at, worktree_path} <-
           inspected_workspace(inspection, candidate.workspace_id),
         validator_params = validator_params(candidate, worktree_path),
         {:ok, action_result} <-
           execute(
             executor,
             candidate.program["action"],
             validator_params,
             worktree_path,
             executor_opts,
             :validator_execution_failed
           ) do
      verify_report(candidate.program, observed_tree_oid, action_result, tree_observed_at)
    end
  rescue
    _exception -> {:error, :candidate_verification_failed}
  catch
    _kind, _reason -> {:error, :candidate_verification_failed}
  end

  defp normalize_candidate(candidate) when is_map(candidate) and not is_struct(candidate) do
    with true <- Enum.all?(Map.keys(candidate), &is_binary/1),
         program when is_map(program) <- Map.get(candidate, "validation_program"),
         :ok <- ValidationProgram.validate(program),
         :ok <- validate_attestation_presence(candidate, program["profile_id"]),
         true <- exact_candidate_keys?(candidate, program["profile_id"]),
         {:ok, workspace_id} <- bounded_id(candidate["workspace_id"], :invalid_workspace_id),
         {:ok, review_attestation_id} <-
           review_attestation_id(candidate, program["profile_id"]),
         {:ok, _json} <- Jason.encode(candidate) do
      {:ok,
       %{
         program: program,
         workspace_id: workspace_id,
         review_attestation_id: review_attestation_id
       }}
    else
      {:error, reason}
      when reason in [
             :invalid_workspace_id,
             :invalid_review_attestation_id,
             :review_attestation_forbidden,
             :review_attestation_required
           ] ->
        {:error, reason}

      _other ->
        {:error, :invalid_candidate}
    end
  end

  defp normalize_candidate(_candidate), do: {:error, :invalid_candidate}

  defp validate_attestation_presence(candidate, "security_regression") do
    if Map.has_key?(candidate, "review_attestation_id"),
      do: :ok,
      else: {:error, :review_attestation_required}
  end

  defp validate_attestation_presence(candidate, _profile_id) do
    if Map.has_key?(candidate, "review_attestation_id"),
      do: {:error, :review_attestation_forbidden},
      else: :ok
  end

  defp exact_candidate_keys?(candidate, "security_regression") do
    MapSet.new(Map.keys(candidate)) ==
      MapSet.new(~w[review_attestation_id validation_program workspace_id])
  end

  defp exact_candidate_keys?(candidate, _profile_id) do
    MapSet.new(Map.keys(candidate)) == MapSet.new(~w[validation_program workspace_id])
  end

  defp review_attestation_id(candidate, "security_regression") do
    bounded_id(candidate["review_attestation_id"], :invalid_review_attestation_id)
  end

  defp review_attestation_id(_candidate, _profile_id), do: {:ok, nil}

  defp normalize_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      normalize_keyword_options(opts)
    else
      {:error, :invalid_options}
    end
  end

  defp normalize_options(_opts), do: {:error, :invalid_options}

  defp normalize_keyword_options(opts) do
    keys = Keyword.keys(opts)

    if Enum.all?(keys, &(&1 in @allowed_option_keys)) and
         length(keys) == length(Enum.uniq(keys)) do
      with {:ok, agent_id} <- bounded_id(Keyword.get(opts, :agent_id), :invalid_agent_id),
           {:ok, task_id} <- bounded_id(Keyword.get(opts, :task_id), :invalid_task_id),
           {:ok, caller_id} <- optional_id(Keyword.get(opts, :caller_id), :invalid_caller_id),
           {:ok, authority} <- canonical_authority(Keyword.get(opts, :signing_authority)),
           :ok <- authority_matches_agent(authority, agent_id) do
        {:ok,
         %{
           agent_id: agent_id,
           caller_id: caller_id,
           task_id: task_id,
           signing_authority: authority
         }}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp canonical_authority(authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, %SigningAuthority{} = canonical} -> {:ok, canonical}
      _error -> {:error, :invalid_signing_authority}
    end
  end

  defp authority_matches_agent(%SigningAuthority{} = authority, agent_id) do
    if Map.get(authority, :principal_id) == agent_id,
      do: :ok,
      else: {:error, :signing_authority_principal_mismatch}
  end

  defp normalize_timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, utc_datetime} <- DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, DateTime.to_iso8601(utc_datetime, :extended)}
    else
      _error -> {:error, :invalid_observed_at}
    end
  end

  defp normalize_timestamp(_value), do: {:error, :invalid_observed_at}

  # Workspace inspection accepts no path input. A platform temp directory gives
  # ActionsExecutor a neutral absolute workdir without granting caller path authority.
  defp inspection_workdir do
    case System.tmp_dir() do
      path when is_binary(path) ->
        expanded = Path.expand(path)

        if valid_absolute_path?(expanded),
          do: {:ok, expanded},
          else: {:error, :candidate_verification_unavailable}

      _unavailable ->
        {:error, :candidate_verification_unavailable}
    end
  end

  defp actions_executor do
    executor = Config.coding_candidate_actions_executor()

    if is_atom(executor) and Code.ensure_loaded?(executor) and
         function_exported?(executor, :execute_structured, 4) do
      {:ok, executor}
    else
      {:error, :candidate_verification_unavailable}
    end
  end

  defp executor_opts(auth, approval_timeout_ms) do
    [agent_id: auth.agent_id]
    |> maybe_append_caller(auth.caller_id)
    |> Kernel.++(
      task_id: auth.task_id,
      signing_authority: auth.signing_authority,
      approval_timeout_ms: approval_timeout_ms
    )
  end

  defp maybe_append_caller(opts, nil), do: opts
  defp maybe_append_caller(opts, caller_id), do: opts ++ [caller_id: caller_id]

  defp execute(executor, action, params, workdir, opts, failure) do
    case executor.execute_structured(action, params, workdir, opts) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, failure}
      _unexpected -> {:error, failure}
    end
  rescue
    _exception -> {:error, failure}
  catch
    _kind, _reason -> {:error, failure}
  end

  defp inspected_workspace(inspection, expected_workspace_id)
       when is_map(inspection) and not is_struct(inspection) do
    with {:ok, true} <- inspect_value(inspection, :exists),
         {:ok, ^expected_workspace_id} <- inspect_value(inspection, :workspace_id),
         {:ok, tree_oid} <- inspect_value(inspection, :committable_tree_oid),
         true <- valid_oid?(tree_oid),
         {:ok, tree_observed_at} <-
           inspect_value(inspection, :committable_tree_observed_at),
         {:ok, tree_observed_at} <- normalize_timestamp(tree_observed_at),
         {:ok, worktree_path} <- inspect_value(inspection, :worktree_path),
         true <- valid_absolute_path?(worktree_path) do
      {:ok, tree_oid, tree_observed_at, worktree_path}
    else
      _other -> {:error, :workspace_inspection_failed}
    end
  end

  defp inspected_workspace(_inspection, _expected_workspace_id),
    do: {:error, :workspace_inspection_failed}

  defp inspect_value(map, key) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      _missing_or_ambiguous -> :error
    end
  end

  defp validator_params(candidate, worktree_path) do
    bound =
      case candidate.program["profile_id"] do
        "default" ->
          %{"path" => worktree_path, "workspace_id" => candidate.workspace_id}

        "cross_app" ->
          %{"workspace_id" => candidate.workspace_id}

        "security_regression" ->
          %{"review_attestation_id" => candidate.review_attestation_id}
      end

    Map.merge(bound, candidate.program["static_parameters"])
  end

  defp verify_report(program, observed_tree_oid, action_result, observed_at) do
    case CandidateVerificationCore.verify(program, observed_tree_oid, action_result, observed_at) do
      {:ok, report} when is_map(report) and not is_struct(report) -> {:ok, report}
      _error -> {:error, :candidate_verification_failed}
    end
  rescue
    _exception -> {:error, :candidate_verification_failed}
  catch
    _kind, _reason -> {:error, :candidate_verification_failed}
  end

  defp optional_id(nil, _error), do: {:ok, nil}
  defp optional_id(value, error), do: bounded_id(value, error)

  defp bounded_id(value, error) do
    if safe_nonblank_text?(value, @max_id_bytes), do: {:ok, value}, else: {:error, error}
  end

  defp safe_nonblank_text?(value, maximum) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum and
      String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, <<0>>) and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_absolute_path?(path) do
    safe_nonblank_text?(path, @max_path_bytes) and Path.type(path) == :absolute
  end

  defp valid_oid?(value),
    do: is_binary(value) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)
end
