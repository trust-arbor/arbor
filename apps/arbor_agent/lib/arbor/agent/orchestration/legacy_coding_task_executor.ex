defmodule Arbor.Agent.Orchestration.LegacyCodingTaskExecutor do
  @moduledoc """
  Legacy `Arbor.Contracts.Agent.TaskExecutor` for structured `coding_change` tasks.

  This is the Phase 6 operator rollback path. It accepts **only** the strict flat
  JSON compatibility envelope (`kind: "coding_change"` plus known coding fields),
  validates field types, and invokes the public
  `Arbor.Actions.authorize_and_execute/4` facade for
  `Arbor.Actions.Coding.ProduceReviewableChange`.

  It deliberately does **not** accept versioned `plan` input or non-default
  reviewed profiles — those belong to the pipeline executor. Task payloads can
  never select the legacy vs pipeline route; only the operator-only runtime
  selector `ARBOR_CODING_EXECUTOR` (evaluated at config load) may.

  Results are returned in the public `TaskArtifacts.normalize/1` shape used by
  other TaskExecutor implementations.
  """

  @behaviour Arbor.Contracts.Agent.TaskExecutor

  alias Arbor.Actions.Coding.ProduceReviewableChange
  alias Arbor.Agent.Orchestration.TaskArtifacts
  alias Arbor.Contracts.Security.{AuthContext, SignedRequest, SigningAuthority}

  @kind "coding_change"
  @produce_reviewable_change_resource "arbor://action/coding/produce_reviewable_change"
  @signing_purpose :legacy_coding_task_executor

  @required_keys ~w(task repo_path acp_agent)
  @optional_keys ~w(base_ref branch_name worktree_base_dir open_pr submit_review)
  @allowed_task_keys MapSet.new(["kind" | @required_keys ++ @optional_keys])

  @allowed_context_keys MapSet.new(~w(task_id timeout caller_id metadata))

  @max_action_metric_entries 24
  @max_action_metric_list_items 32
  @max_action_metric_depth 3
  @max_action_metric_key_bytes 128
  @max_action_metric_string_bytes 1_024
  @max_action_metrics_encoded_bytes 16_384

  @forbidden_task_keys MapSet.new(~w(
    action_executor
    actions
    actions_executor
    agent_id
    authorization
    authorizer
    capabilities
    coding_executor
    coding_pipeline_path
    edges
    engine
    engine_module
    executor
    graph
    graph_path
    identity
    identity_private_key
    key_file
    module
    nodes
    path
    pipeline
    pipeline_path
    principal_id
    private_key
    private_keys
    profile
    review_profile
    signer
    signing_key
    signing_key_file
    signing_keys
    task_id
  ))

  @forbidden_context_keys MapSet.new(~w(
    authorization
    signer
    agent_id
    engine
    engine_module
    action_executor
    actions_executor
    graph
    graph_path
    capabilities
    identity
    authorizer
    private_key
    signing_key
    identity_private_key
    executor
    coding_executor
  ))

  @doc """
  Run the legacy ProduceReviewableChange action for `agent_id`.

  `task` must be a JSON-clean string-keyed map with `kind: "coding_change"` and
  the flat compatibility fields only. `context` must include a nonblank
  `task_id`; optional `timeout` / `caller_id` / `metadata` are accepted as data
  only (never as control authority).
  """
  @impl true
  @spec run(String.t(), term(), map() | keyword()) ::
          {:ok, map()}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:pending_approval, String.t()}}
          | {:error, term()}
  def run(agent_id, task, context) when is_binary(agent_id) do
    started_at = System.monotonic_time(:millisecond)

    with :ok <- validate_agent_id(agent_id),
         {:ok, exec_ctx} <- validate_context(context),
         {:ok, params} <- validate_and_build_params(task),
         {:ok, action_context} <- build_action_context(agent_id, exec_ctx),
         params <- maybe_put_timeout(params, exec_ctx) do
      invoke_action(agent_id, params, action_context, started_at)
    end
  end

  def run(_agent_id, _task, _context), do: {:error, :invalid_agent_id}

  # ===========================================================================
  # Validation
  # ===========================================================================

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    if String.valid?(agent_id) and String.trim(agent_id) != "",
      do: :ok,
      else: {:error, :invalid_agent_id}
  end

  defp validate_context(context) when is_map(context) and not is_struct(context) do
    with :ok <- ensure_string_keyed_json_map(context, :non_json_context),
         :ok <- reject_forbidden_keys(context, @forbidden_context_keys, :forbidden_context_key),
         :ok <- reject_unknown_keys(context, @allowed_context_keys, :unknown_context_key),
         {:ok, task_id} <- require_nonblank(context, "task_id"),
         {:ok, extras} <- extract_context_extras(context) do
      {:ok, Map.merge(%{task_id: task_id}, extras)}
    end
  end

  defp validate_context(_context), do: {:error, :invalid_context}

  defp validate_and_build_params(task) when is_map(task) and not is_struct(task) do
    with :ok <- ensure_string_keyed_json_map(task, :non_json_task),
         :ok <- ensure_json_encodable(task, :non_json_task),
         :ok <- reject_plan_input(task),
         :ok <- reject_non_default_review_profile(task),
         :ok <- reject_forbidden_task_keys(task),
         :ok <- require_kind(task),
         :ok <- reject_unknown_keys(task, @allowed_task_keys, :unknown_task_key),
         {:ok, task_text} <- require_task_text(task),
         {:ok, repo_path} <- require_trimmed_string(task, "repo_path"),
         {:ok, acp_agent} <- require_trimmed_string(task, "acp_agent"),
         {:ok, base_ref} <- optional_trimmed_string(task, "base_ref"),
         {:ok, branch_name} <- optional_trimmed_string(task, "branch_name"),
         {:ok, worktree_base_dir} <- optional_trimmed_string(task, "worktree_base_dir"),
         {:ok, open_pr} <- optional_boolean(task, "open_pr", false),
         {:ok, submit_review} <- optional_boolean(task, "submit_review", true) do
      params =
        %{
          task: task_text,
          repo_path: repo_path,
          acp_agent: acp_agent,
          open_pr: open_pr,
          submit_review: submit_review
        }
        |> put_optional(:base_ref, base_ref)
        |> put_optional(:branch_name, branch_name)
        |> put_optional(:worktree_base_dir, worktree_base_dir)

      {:ok, params}
    end
  end

  defp validate_and_build_params(_task), do: {:error, :invalid_task}

  defp reject_plan_input(%{"plan" => _plan}), do: {:error, :legacy_executor_rejects_plan}
  defp reject_plan_input(_task), do: :ok

  # Flat envelope has no review_profile; any profile field is a non-default
  # reviewed-profile attempt that the legacy action does not support.
  defp reject_non_default_review_profile(task) do
    cond do
      Map.has_key?(task, "review_profile") ->
        {:error, {:legacy_executor_rejects_review_profile, Map.get(task, "review_profile")}}

      Map.has_key?(task, "profile") ->
        {:error, {:legacy_executor_rejects_review_profile, Map.get(task, "profile")}}

      true ->
        :ok
    end
  end

  defp require_kind(%{"kind" => @kind}), do: :ok

  defp require_kind(%{"kind" => kind}) when is_binary(kind),
    do: {:error, {:unsupported_task_kind, kind}}

  defp require_kind(%{"kind" => _kind}), do: {:error, {:invalid_field_type, "kind"}}
  defp require_kind(_task), do: {:error, :missing_task_kind}

  defp require_task_text(task) do
    case Map.fetch(task, "task") do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, {:blank_field, "task"}},
          else: {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field_type, "task"}}

      :error ->
        {:error, {:missing_field, "task"}}
    end
  end

  defp require_trimmed_string(task, field) do
    case Map.fetch(task, field) do
      {:ok, value} -> normalize_trimmed_string(value, field)
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp optional_trimmed_string(task, field) do
    case Map.fetch(task, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> normalize_trimmed_string(value, field)
    end
  end

  defp normalize_trimmed_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:blank_field, field}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_trimmed_string(_value, field), do: {:error, {:invalid_field_type, field}}

  defp optional_boolean(task, field, default) do
    case Map.fetch(task, field) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} -> normalize_boolean(value, field)
    end
  end

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean("1", _field), do: {:ok, true}
  defp normalize_boolean("0", _field), do: {:ok, false}

  defp normalize_boolean(value, field) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, {:invalid_field_type, field}}
    end
  end

  defp normalize_boolean(_value, field), do: {:error, {:invalid_field_type, field}}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp require_nonblank(map, field) do
    case Map.get(map, field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:blank_field, field}}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, {:missing_field, field}}

      _other ->
        {:error, {:invalid_field_type, field}}
    end
  end

  defp extract_context_extras(context) do
    Enum.reduce_while(["timeout", "caller_id", "metadata"], {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(context, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize_context_extra(key, value) do
            {:ok, normalized} ->
              atom_key =
                case key do
                  "timeout" -> :timeout
                  "caller_id" -> :caller_id
                  "metadata" -> :metadata
                end

              {:cont, {:ok, Map.put(acc, atom_key, normalized)}}

            {:error, _} = err ->
              {:halt, err}
          end
      end
    end)
  end

  defp normalize_context_extra("timeout", value)
       when is_integer(value) and value > 0 and not is_boolean(value) do
    {:ok, value}
  end

  defp normalize_context_extra("timeout", _value), do: {:error, {:invalid_field_type, "timeout"}}

  defp normalize_context_extra("caller_id", value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:blank_field, "caller_id"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_context_extra("caller_id", _value),
    do: {:error, {:invalid_field_type, "caller_id"}}

  defp normalize_context_extra("metadata", value)
       when is_map(value) and not is_struct(value) do
    case ensure_string_keyed_json_map(value, :non_json_context) do
      :ok -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp normalize_context_extra("metadata", _value),
    do: {:error, {:invalid_field_type, "metadata"}}

  defp reject_forbidden_task_keys(task) do
    reject_forbidden_keys(task, @forbidden_task_keys, :forbidden_task_key)
  end

  defp reject_forbidden_keys(map, forbidden, error_tag) do
    case Enum.find(Map.keys(map), &MapSet.member?(forbidden, &1)) do
      nil -> :ok
      key -> {:error, {error_tag, key}}
    end
  end

  defp reject_unknown_keys(map, allowed, error_tag) do
    case Enum.find(Map.keys(map), &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      key -> {:error, {error_tag, key}}
    end
  end

  defp ensure_string_keyed_json_map(map, error_tag)
       when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, {error_tag, :non_string_key}}}

        not String.valid?(key) ->
          {:halt, {:error, {error_tag, :invalid_utf8_key}}}

        true ->
          case ensure_json_value(value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {error_tag, reason}}}
          end
      end
    end)
  end

  defp ensure_json_value(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8_string}
  end

  defp ensure_json_value(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp ensure_json_value([]), do: :ok

  defp ensure_json_value([head | tail]) do
    with :ok <- ensure_json_value(head) do
      ensure_json_value(tail)
    end
  end

  defp ensure_json_value(%_{}), do: {:error, :struct_not_json}

  defp ensure_json_value(map) when is_map(map) do
    ensure_string_keyed_json_map(map, :nested_map)
  end

  defp ensure_json_value(value) when is_atom(value), do: {:error, :atom_not_json}
  defp ensure_json_value(value) when is_pid(value), do: {:error, :pid_not_json}
  defp ensure_json_value(value) when is_function(value), do: {:error, :function_not_json}
  defp ensure_json_value(value) when is_reference(value), do: {:error, :reference_not_json}
  defp ensure_json_value(value) when is_port(value), do: {:error, :port_not_json}
  defp ensure_json_value(value) when is_tuple(value), do: {:error, :tuple_not_json}
  defp ensure_json_value(_value), do: {:error, :non_json_value}

  defp ensure_json_encodable(value, error_tag) do
    case Jason.encode(value) do
      {:ok, _encoded} -> :ok
      {:error, _reason} -> {:error, {error_tag, :invalid_encoding}}
    end
  rescue
    _exception -> {:error, {error_tag, :invalid_encoding}}
  end

  # ===========================================================================
  # Invocation
  # ===========================================================================

  defp build_action_context(agent_id, exec_ctx) do
    context =
      %{
        agent_id: agent_id,
        task_id: exec_ctx.task_id
      }
      |> maybe_put_context(:caller_id, Map.get(exec_ctx, :caller_id))
      |> maybe_put_context(:metadata, Map.get(exec_ctx, :metadata))
      |> maybe_put_context(:timeout, Map.get(exec_ctx, :timeout))

    # Guard: task/context data never injects authority or route selection.
    with :ok <- ensure_no_authority_keys(context) do
      {:ok, context}
    end
  end

  defp maybe_put_context(map, _key, nil), do: map
  defp maybe_put_context(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_timeout(params, exec_ctx) do
    case Map.get(exec_ctx, :timeout) do
      timeout when is_integer(timeout) and timeout > 0 ->
        Map.put_new(params, :timeout, timeout)

      _ ->
        params
    end
  end

  defp ensure_no_authority_keys(context) do
    forbidden =
      MapSet.new([
        :authorization,
        :signer,
        :capabilities,
        :identity,
        :private_key,
        :signing_key,
        :executor,
        :coding_executor,
        "authorization",
        "signer",
        "capabilities",
        "identity",
        "private_key",
        "signing_key",
        "executor",
        "coding_executor"
      ])

    case Enum.find(Map.keys(context), &MapSet.member?(forbidden, &1)) do
      nil -> :ok
      key -> {:error, {:forbidden_context_key, key}}
    end
  end

  defp invoke_action(agent_id, params, action_context, started_at) do
    with {:ok, security} <- security_facade(),
         {:ok, authority} <- acquire_signing_authority(security, agent_id) do
      try do
        with {:ok, signed_context} <-
               sign_action_context(security, agent_id, authority, action_context) do
          do_invoke_action(agent_id, params, signed_context, started_at)
        end
      after
        # Broker monitors this process, but normal terminal outcomes must
        # release the authority before returning to TaskStore.
        _ = close_signing_authority(security, authority)
      end
    end
  end

  defp do_invoke_action(agent_id, params, action_context, started_at) do
    actions = actions_module()

    case actions.authorize_and_execute(
           agent_id,
           ProduceReviewableChange,
           params,
           action_context
         ) do
      {:ok, :pending_approval, approval_id} when is_binary(approval_id) ->
        {:ok, :pending_approval, approval_id}

      {:error, {:pending_approval, _approval_id}} = pending ->
        pending

      {:ok, result} ->
        normalize_success(result, started_at)

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_action_result, other}}
    end
  rescue
    e -> {:error, {:legacy_coding_action_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:legacy_coding_action_exit, reason}}
    kind, reason -> {:error, {:legacy_coding_action_throw, {kind, reason}}}
  end

  # -------------------------------------------------------------------------
  # Signing authority (reload-stable, owner-bound, closed after the action)
  # -------------------------------------------------------------------------

  defp security_facade do
    security = security_module()

    if is_atom(security) and Code.ensure_loaded?(security) and
         function_exported?(security, :load_signing_key, 1) and
         function_exported?(security, :build_signing_authority_acquisition_proof, 3) and
         function_exported?(security, :open_signing_authority, 1) and
         function_exported?(security, :sign_with_authority, 2) and
         function_exported?(security, :verify_request, 1) and
         function_exported?(security, :close_signing_authority, 1) do
      {:ok, security}
    else
      {:error, :security_unavailable}
    end
  end

  # The decrypted key exists only while the owner-bound possession proof is
  # constructed. The broker retains the reload-stable authority, never this
  # key or a closure over it.
  defp acquire_signing_authority(security, agent_id) do
    with {:ok, private_key} <- security.load_signing_key(agent_id),
         true <- is_binary(private_key) and private_key != "",
         {:ok, proof} <-
           security.build_signing_authority_acquisition_proof(
             agent_id,
             private_key,
             purpose: @signing_purpose,
             owner: self()
           ),
         {:ok, opened_authority} <- security.open_signing_authority(proof) do
      case SigningAuthority.canonicalize(opened_authority) do
        {:ok, authority} ->
          {:ok, authority}

        {:error, reason} ->
          _ = close_signing_authority(security, opened_authority)
          {:error, {:signing_authority_acquisition_failed, reason}}
      end
    else
      false -> {:error, :invalid_signing_key}
      {:error, :no_signing_key} -> {:error, :no_signing_key}
      {:error, reason} -> {:error, {:signing_authority_acquisition_failed, reason}}
      other -> {:error, {:signing_authority_acquisition_failed, other}}
    end
  rescue
    exception ->
      {:error, {:signing_authority_acquisition_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:signing_authority_acquisition_failed, {kind, reason}}}
  end

  defp close_signing_authority(security, authority) do
    case security.close_signing_authority(authority) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_close_result, other}}
    end
  rescue
    exception -> {:error, {:authority_close_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:authority_close_failed, {kind, reason}}}
  end

  defp sign_action_context(security, agent_id, %SigningAuthority{} = authority, action_context) do
    resource = produce_reviewable_change_resource()

    with {:ok, %SignedRequest{} = signed_request} <-
           security.sign_with_authority(authority, resource),
         :ok <- validate_signed_request_binding(signed_request, agent_id, resource),
         {:ok, ^agent_id} <- security.verify_request(signed_request) do
      auth_context =
        AuthContext.new(agent_id, signed_request: signed_request)
        |> AuthContext.mark_verified()

      {:ok,
       action_context
       |> Map.put(:signed_request, signed_request)
       |> Map.put(:auth_context, auth_context)
       |> Map.put(:signing_authority, authority)}
    else
      {:error, reason} -> {:error, {:legacy_coding_authority_signing_failed, reason}}
      _other -> {:error, {:legacy_coding_authority_signing_failed, :invalid_signed_request}}
    end
  rescue
    exception ->
      {:error, {:legacy_coding_authority_signing_failed, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:legacy_coding_authority_signing_failed, {kind, reason}}}
  end

  defp validate_signed_request_binding(
         %SignedRequest{agent_id: agent_id, payload: payload},
         agent_id,
         payload
       ),
       do: :ok

  defp validate_signed_request_binding(_signed_request, _agent_id, _payload),
    do: {:error, :signed_request_binding_mismatch}

  defp produce_reviewable_change_resource do
    if function_exported?(Arbor.Actions, :canonical_uri_for, 2) do
      case Arbor.Actions.canonical_uri_for(ProduceReviewableChange, %{}) do
        @produce_reviewable_change_resource = resource -> resource
        resource when is_binary(resource) and resource != "" -> resource
        _other -> @produce_reviewable_change_resource
      end
    else
      @produce_reviewable_change_resource
    end
  end

  defp normalize_success(result, started_at)
       when is_map(result) and not is_struct(result) do
    wall_clock_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

    result = Map.put(result, "metrics", legacy_metrics(result, wall_clock_ms))
    result = Map.delete(result, :metrics)
    normalized = TaskArtifacts.normalize(result)

    with :ok <- ensure_result_json_clean(normalized) do
      {:ok, normalized}
    end
  end

  defp normalize_success(_result, _started_at), do: {:error, :invalid_legacy_coding_result}

  defp legacy_metrics(result, wall_clock_ms) do
    preserved = preserved_action_metrics(result)

    Map.merge(preserved, %{
      "execution_path" => "legacy",
      "wall_clock_ms" => wall_clock_ms,
      "validation_attempts" => evidence_presence_count(result_value(result, :validation)),
      "validation_command_count" => validation_command_count(result_value(result, :validation)),
      "review_attempts" => evidence_count(result_value(result, :review)),
      "protocol_retry_count" => 0,
      "validation_rework_count" => 0,
      "review_rework_count" => 0,
      "total_rework_count" => 0
    })
  end

  defp preserved_action_metrics(result) do
    metrics = result_value(result, :metrics)

    with true <- is_map(metrics) and not is_struct(metrics),
         {:ok, clean} <- clean_metric_map(metrics, 0),
         {:ok, encoded} <- Jason.encode(clean),
         true <- byte_size(encoded) <= @max_action_metrics_encoded_bytes do
      clean
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp clean_metric_map(map, depth)
       when depth <= @max_action_metric_depth and
              map_size(map) <= @max_action_metric_entries do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, clean_key} <- clean_metric_key(key),
           false <- Map.has_key?(acc, clean_key),
           {:ok, clean_value} <- clean_metric_value(value, depth + 1) do
        {:cont, {:ok, Map.put(acc, clean_key, clean_value)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp clean_metric_map(_map, _depth), do: :error

  defp clean_metric_key(key) when is_atom(key), do: clean_metric_key(Atom.to_string(key))

  defp clean_metric_key(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) <= @max_action_metric_key_bytes,
      do: {:ok, key},
      else: :error
  end

  defp clean_metric_key(_key), do: :error

  defp clean_metric_value(_value, depth) when depth > @max_action_metric_depth, do: :error

  defp clean_metric_value(value, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp clean_metric_value(value, _depth) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_action_metric_string_bytes,
      do: {:ok, value},
      else: :error
  end

  defp clean_metric_value(%_{}, _depth), do: :error
  defp clean_metric_value(map, depth) when is_map(map), do: clean_metric_map(map, depth)

  defp clean_metric_value(list, depth) when is_list(list) do
    if length(list) <= @max_action_metric_list_items do
      Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
        case clean_metric_value(value, depth + 1) do
          {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp clean_metric_value(_value, _depth), do: :error

  defp evidence_count(nil), do: 0
  defp evidence_count([]), do: 0
  defp evidence_count(list) when is_list(list), do: length(list)

  defp evidence_count(map) when is_map(map) and not is_struct(map) do
    if map_size(map) == 0, do: 0, else: 1
  end

  defp evidence_count(_evidence), do: 0

  defp evidence_presence_count(nil), do: 0
  defp evidence_presence_count([]), do: 0

  defp evidence_presence_count(map) when is_map(map) and not is_struct(map) do
    if map_size(map) == 0, do: 0, else: 1
  end

  defp evidence_presence_count(list) when is_list(list), do: 1
  defp evidence_presence_count(_evidence), do: 0

  defp validation_command_count(list) when is_list(list), do: length(list)
  defp validation_command_count(_evidence), do: 0

  defp result_value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp ensure_result_json_clean(result) when is_map(result) do
    case Jason.encode(result) do
      {:ok, _encoded} -> :ok
      {:error, reason} -> {:error, {:non_json_result, reason}}
    end
  rescue
    _exception -> {:error, :non_json_result}
  end

  defp ensure_result_json_clean(_result), do: {:error, :non_json_result}

  defp actions_module do
    Application.get_env(:arbor_agent, :legacy_coding_actions_module, Arbor.Actions)
  end

  defp security_module do
    Application.get_env(:arbor_agent, :legacy_coding_security_module, Arbor.Security)
  end
end
