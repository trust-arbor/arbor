defmodule Arbor.Actions.Coding.ReviewedValidation do
  @moduledoc """
  Pipeline-internal validation gate with structured approval outcomes.

  Compiler/manifest pins the underlying validation action name and static
  parameters. This action never accepts module atoms or free-form DOT selection
  of the nested validator.

  Graph-owned branching consumes:

    * `interaction_outcome=""` — unattended authorize or approved; nested
      validator executed exactly once; nested result fields are merged in
    * `interaction_outcome="rework"` — operator rework; **zero** nested
      validator calls; request_id + note only (no fabricated evidence)
    * `interaction_outcome="denied"` — operator deny; **zero** nested calls

  Approve retries the exact pinned validation once via `approved_invocation`
  and a **fresh** exact-resource SignedRequest — never the outer nonce.
  """

  use Jido.Action,
    name: "coding_reviewed_validation",
    description:
      "Request operator approval then run the compiler-pinned validation action (pipeline-internal)",
    category: "coding",
    tags: ["coding", "validation", "approval", "pipeline_internal"],
    schema: [
      pinned_action: [
        type: :string,
        required: true,
        doc: "Exact registered nested validation action name (compiler-pinned)"
      ],
      pinned_profile_id: [
        type: :string,
        required: true,
        doc: "Validation profile id that owns the pin"
      ],
      pinned_params_json: [
        type: :string,
        required: true,
        doc: "JSON object of exact nested static params (compiler-pinned)"
      ],
      path: [
        type: :string,
        required: false,
        doc: "Worktree path when the nested action requires it"
      ],
      workspace_id: [
        type: :string,
        required: false,
        doc: "Active workspace lease id when the nested action requires it"
      ],
      review_attestation_id: [
        type: :string,
        required: false,
        doc: "Security-regression attestation id when required by the pin"
      ],
      timeout: [
        type: :non_neg_integer,
        doc:
          "ExecHandler-clamped nested validator timeout binding (default profile); not approval wait"
      ],
      stage_timeout: [
        type: :non_neg_integer,
        doc:
          "ExecHandler-clamped nested validator stage_timeout binding (cross_app/security profiles)"
      ],
      cross_app_progress: [
        type: {:or, [:map, :string]},
        required: false,
        doc: "Compiler-owned CrossApp continuation progress or the empty seed sentinel"
      ],
      cross_app_progress_binding: [
        type: {:or, [:map, :string]},
        required: false,
        doc: "Compiler-owned CrossApp continuation identity binding or the empty seed sentinel"
      ],
      coding_plan_work_packet_digest: [
        type: :string,
        required: false,
        doc: "Compiler-owned digest binding CrossApp evidence to the frozen work packet"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.ContractChange.Core, as: ContractChangeCore
  alias Arbor.Contracts.Comms.ApprovalAnswer
  alias Arbor.Contracts.Security.{AuthContext, SignedRequest, SigningAuthority}

  @default_approval_timeout 60_000
  @max_action_name_bytes 200
  @max_profile_id_bytes 128
  @max_params_json_bytes 16_384

  # Closed profile-owned validator allowlist. Exact action names and modules
  # only — forged pins cannot reach arbitrary registered syscalls.
  @allowed_validators %{
    "mix_compile" => Arbor.Actions.Mix.Compile,
    "coding_cross_app_validate" => Arbor.Actions.Coding.CrossApp.Validate,
    "coding_security_regression_validate" => Arbor.Actions.Coding.SecurityRegression.Validate,
    "coding_contract_change_validate" => Arbor.Actions.Coding.ContractChange.Validate
  }

  @profile_owned_actions %{
    "default" => "mix_compile",
    "cross_app" => "coding_cross_app_validate",
    "security_regression" => "coding_security_regression_validate",
    "contract_change" => "coding_contract_change_validate"
  }

  def taint_roles do
    %{
      pinned_action: :control,
      pinned_profile_id: :control,
      pinned_params_json: :control,
      path: {:control, requires: [:path_traversal]},
      workspace_id: :control,
      review_attestation_id: :control,
      timeout: :control,
      stage_timeout: :control,
      cross_app_progress: :control,
      cross_app_progress_binding: :control,
      coding_plan_work_packet_digest: :control
    }
  end

  def effect_class, do: :local_write

  @doc """
  Parameter-sensitive replay class.

  Only the exact compiler-pinned `cross_app` / `coding_cross_app_validate`
  pin is `:idempotent_with_key`. Every other profile, pin, or malformed
  input fails closed to `:side_effecting`. There is no arity-0 keyed
  declaration — name-only classification stays side-effecting.
  """
  @spec execution_idempotency(map()) ::
          :idempotent | :idempotent_with_key | :side_effecting | :read_only
  def execution_idempotency(params) when is_map(params) do
    case resolve_pin(params) do
      {:ok, %{profile_id: "cross_app", action: "coding_cross_app_validate"}} ->
        :idempotent_with_key

      _other ->
        :side_effecting
    end
  end

  def execution_idempotency(_params), do: :side_effecting

  @doc """
  Closed set of nested validators the compiler may pin.

  Runtime selection is only from the immutable pin string against
  `@allowed_validators`. This list exists so execution manifests and authority
  horizons transitively bind every nested validator capability URI.
  """
  @spec execution_dependencies() :: [module()]
  def execution_dependencies do
    @allowed_validators
    |> Map.values()
    |> Enum.sort_by(&Atom.to_string/1)
  end

  @doc "Exact action names admitted as nested validators (closed set)."
  @spec allowed_validator_names() :: [String.t()]
  def allowed_validator_names, do: @allowed_validators |> Map.keys() |> Enum.sort()

  @doc "Exact module for an admitted nested validator name, or error."
  @spec allowed_validator_module(String.t()) :: {:ok, module()} | {:error, term()}
  def allowed_validator_module(name) when is_binary(name) do
    case Map.fetch(@allowed_validators, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:disallowed_pinned_action, name}}
    end
  end

  def allowed_validator_module(_name), do: {:error, :invalid_pinned_action}

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def run(params, context) when is_map(params) and is_map(context) do
    Actions.emit_started(__MODULE__, %{})

    # Outer coding_reviewed_validation is pipeline-internal and must already be
    # admitted by the Engine pin / allow_pipeline_internal path. Approval is
    # gated here only against the exact nested validation resource — never
    # against an open-ended action name supplied by the graph author.
    result =
      with {:ok, pin} <- resolve_pin(params),
           {:ok, context} <- put_cross_app_window_context(pin, params, context),
           {:ok, module} <- resolve_pinned_module(pin),
           {:ok, nested_params} <- build_nested_params(pin, params),
           resource = Actions.canonical_uri_for(module, nested_params),
           agent_id = context_agent_id(context),
           {:ok, approval_timeout_ms} <- approval_timeout(params, context),
           {:ok, signed_request} <- fresh_signed_request(resource, context),
           auth_context = put_signed_request(context, signed_request) do
        case authorize_validation(agent_id, resource, nested_params, auth_context, pin) do
          :authorized ->
            execute_nested_once(
              agent_id,
              module,
              nested_params,
              auth_context,
              nil,
              "",
              pin.profile_id
            )

          {:pending_approval, request_id} ->
            await_and_decide(
              agent_id,
              request_id,
              module,
              nested_params,
              auth_context,
              approval_timeout_ms,
              pin.profile_id
            )

          {:error, reason} ->
            {:error, format_error(reason)}
        end
      else
        {:error, reason} -> {:error, format_error(reason)}
      end

    case result do
      {:ok, payload} = ok ->
        Actions.emit_completed(__MODULE__, %{
          interaction_outcome: payload["interaction_outcome"]
        })

        ok

      {:error, reason} = err ->
        Actions.emit_failed(__MODULE__, reason)
        err
    end
  end

  def run(_params, _context), do: {:error, "invalid_reviewed_validation_params"}

  @cross_app_window_keys [
    {"cross_app_progress", :cross_app_progress},
    {"cross_app_progress_binding", :cross_app_progress_binding},
    {"coding_plan_work_packet_digest", :coding_plan_work_packet_digest}
  ]

  defp put_cross_app_window_context(%{profile_id: "cross_app"}, params, context)
       when is_map(params) and is_map(context) do
    Enum.reduce_while(@cross_app_window_keys, {:ok, context}, fn {string_key, atom_key},
                                                                 {:ok, acc} ->
      case exclusive_param(params, string_key, atom_key) do
        {:error, reason} ->
          {:halt, {:error, reason}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, ""} ->
          {:cont, {:ok, Map.put(acc, string_key, "")}}

        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, string_key, value)}}
      end
    end)
  end

  defp put_cross_app_window_context(_pin, params, context)
       when is_map(params) and is_map(context) do
    Enum.reduce_while(@cross_app_window_keys, {:ok, context}, fn {string_key, atom_key},
                                                                 {:ok, acc} ->
      case exclusive_param(params, string_key, atom_key) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, ""} -> {:cont, {:ok, acc}}
        _other -> {:halt, {:error, :invalid_cross_app_window_context}}
      end
    end)
  end

  defp exclusive_param(params, string_key, atom_key) do
    has_string = Map.has_key?(params, string_key)
    has_atom = Map.has_key?(params, atom_key)

    cond do
      has_string and has_atom -> {:error, :invalid_cross_app_window_context}
      has_string -> {:ok, Map.get(params, string_key)}
      has_atom -> {:ok, Map.get(params, atom_key)}
      true -> {:ok, nil}
    end
  end

  # -- pin resolution --------------------------------------------------------

  defp resolve_pin(params) do
    action = param_string(params, [:pinned_action, "pinned_action"])
    profile_id = param_string(params, [:pinned_profile_id, "pinned_profile_id"])
    params_json = param_string(params, [:pinned_params_json, "pinned_params_json"])

    cond do
      not is_binary(action) or action == "" or byte_size(action) > @max_action_name_bytes ->
        {:error, :invalid_pinned_action}

      String.contains?(action, ".") or String.contains?(action, "Elixir") ->
        # Reject module-looking strings; only closed allowlisted action names.
        {:error, :invalid_pinned_action}

      not Map.has_key?(@allowed_validators, action) ->
        {:error, {:disallowed_pinned_action, action}}

      not is_binary(profile_id) or profile_id == "" or
          byte_size(profile_id) > @max_profile_id_bytes ->
        {:error, :invalid_pinned_profile_id}

      not profile_owns_action?(profile_id, action) ->
        {:error, {:pinned_action_profile_mismatch, profile_id, action}}

      not is_binary(params_json) or params_json == "" or
          byte_size(params_json) > @max_params_json_bytes ->
        {:error, :invalid_pinned_params_json}

      true ->
        case Jason.decode(params_json) do
          {:ok, static} when is_map(static) and not is_struct(static) ->
            if Enum.all?(Map.keys(static), &is_binary/1) do
              {:ok, %{action: action, profile_id: profile_id, static_parameters: static}}
            else
              {:error, :invalid_pinned_params_json}
            end

          _ ->
            {:error, :invalid_pinned_params_json}
        end
    end
  end

  defp profile_owns_action?(profile_id, action) do
    case Map.fetch(@profile_owned_actions, profile_id) do
      {:ok, ^action} -> true
      {:ok, _other} -> false
      # Unknown profile ids are rejected — only reviewed profile owners pin.
      :error -> false
    end
  end

  defp resolve_pinned_module(%{action: action_name}) do
    with {:ok, expected_module} <- allowed_validator_module(action_name),
         {:ok, resolved} <- Actions.name_to_module(action_name),
         true <- resolved == expected_module do
      {:ok, expected_module}
    else
      false ->
        {:error, {:pinned_action_module_mismatch, action_name}}

      {:error, :unknown_action} ->
        {:error, {:unknown_pinned_action, action_name}}

      {:error, _} = error ->
        error
    end
  end

  defp build_nested_params(pin, params) do
    nested =
      pin.static_parameters
      |> atomize_known_keys()
      |> maybe_put_runtime(:path, param_string(params, [:path, "path"]))
      |> maybe_put_runtime(:workspace_id, param_string(params, [:workspace_id, "workspace_id"]))
      |> maybe_put_runtime(
        :review_attestation_id,
        param_string(params, [:review_attestation_id, "review_attestation_id"])
      )
      # ExecHandler clamps the compiler-selected timeout_budget.param onto this
      # outer action at runtime. Prefer that live value over the static pin so
      # every nested validator observes the exact remaining stage budget.
      |> apply_clamped_deadline_binding(params)

    {:ok, nested}
  end

  # Admit either the default-profile `timeout` binding or the compound-profile
  # `stage_timeout` binding. Only the present positive runtime value overrides
  # the matching nested key; other static pin timeouts stay intact.
  defp apply_clamped_deadline_binding(nested, params) do
    case positive_int_param(params, [:stage_timeout, "stage_timeout"]) do
      stage when is_integer(stage) ->
        Map.put(nested, :stage_timeout, stage)

      nil ->
        case positive_int_param(params, [:timeout, "timeout"]) do
          timeout when is_integer(timeout) ->
            Map.put(nested, :timeout, timeout)

          nil ->
            nested
        end
    end
  end

  defp positive_int_param(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        n when is_integer(n) and n > 0 -> n
        _ -> nil
      end
    end)
  end

  defp atomize_known_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      atom_key =
        case key do
          k when is_atom(k) -> k
          "path" -> :path
          "workspace_id" -> :workspace_id
          "warnings_as_errors" -> :warnings_as_errors
          "timeout" -> :timeout
          "test_stage_timeout" -> :test_stage_timeout
          "stage_timeout" -> :stage_timeout
          "review_attestation_id" -> :review_attestation_id
          other when is_binary(other) -> other
        end

      Map.put(acc, atom_key, value)
    end)
  end

  defp maybe_put_runtime(map, _key, nil), do: map
  defp maybe_put_runtime(map, _key, ""), do: map
  defp maybe_put_runtime(map, key, value), do: Map.put(map, key, value)

  # -- authorize -------------------------------------------------------------

  defp authorize_validation(agent_id, resource, nested_params, context, pin) do
    auth_opts = build_auth_opts(agent_id, resource, nested_params, context, pin)

    case Arbor.Trust.authorize(agent_id, resource, :execute, auth_opts) do
      result
      when result == {:ok, :authorized} or
             (is_tuple(result) and elem(result, 0) == :ok and elem(result, 1) == :authorized) ->
        :authorized

      {:ok, :pending_approval, proposal_id} when is_binary(proposal_id) ->
        {:pending_approval, proposal_id}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_authorize_result, other}}
    end
  end

  defp build_auth_opts(agent_id, resource, nested_params, context, pin) do
    signed_request = Map.get(context, :signed_request)

    []
    |> maybe_put(:signed_request, signed_request)
    |> maybe_put(:task_id, context_value(context, :task_id))
    |> maybe_put(:session_id, context_value(context, :session_id))
    |> maybe_put(:approved_invocation, Map.get(context, :approved_invocation))
    |> Keyword.put(
      :approval_context,
      %{
        action: "coding_reviewed_validation",
        resource_uri: resource,
        pinned_action: pin.action,
        pinned_profile_id: pin.profile_id,
        path: Map.get(nested_params, :path) || Map.get(nested_params, "path"),
        agent_id: agent_id
      }
    )
  end

  # -- await + decide --------------------------------------------------------

  defp await_and_decide(
         agent_id,
         request_id,
         module,
         nested_params,
         context,
         approval_timeout_ms,
         profile_id
       ) do
    with {:ok, request_id} <- ApprovalAnswer.validate_request_id(request_id),
         {:ok, decision} <- await_decision(agent_id, request_id, approval_timeout_ms) do
      case decision do
        :approve ->
          execute_nested_once(
            agent_id,
            module,
            nested_params,
            context,
            request_id,
            "",
            profile_id
          )

        {:deny, note} ->
          {:ok, control_payload("denied", request_id, note)}

        {:rework, note} ->
          # Zero nested validator calls — carry id/note only.
          {:ok, control_payload("rework", request_id, note)}
      end
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp await_decision(agent_id, request_id, timeout) do
    if interaction_request?(request_id) do
      await_interaction(agent_id, request_id, timeout)
    else
      await_consensus(request_id, timeout)
    end
  end

  defp await_interaction(agent_id, request_id, timeout) do
    if is_nil(agent_id) do
      {:error, :missing_agent_id}
    else
      case Arbor.Comms.await_interaction_response(request_id, agent_id, timeout: timeout) do
        {:ok, response, metadata} ->
          normalize_decision(response, metadata)

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp await_consensus(proposal_id, timeout) do
    case Arbor.Consensus.await(proposal_id, timeout: timeout) do
      {:ok, decision} when is_map(decision) ->
        case ApprovalAnswer.normalize_consensus_decision(decision) do
          {:ok, :approve} -> {:ok, :approve}
          {:ok, :rework, note} -> {:ok, {:rework, note}}
          {:ok, :deny, note} -> {:ok, {:deny, note}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, :approved} ->
        {:ok, :approve}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_decision(response, metadata) do
    case ApprovalAnswer.normalize(response, metadata) do
      {:ok, :approve} -> {:ok, :approve}
      {:ok, :rework, note} -> {:ok, {:rework, note}}
      {:ok, :deny, note} -> {:ok, {:deny, note}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- nested execute once ---------------------------------------------------

  defp execute_nested_once(
         agent_id,
         module,
         nested_params,
         context,
         request_id,
         note,
         profile_id
       ) do
    resource = Actions.canonical_uri_for(module, nested_params)

    with {:ok, fresh_sr} <- fresh_signed_request(resource, context) do
      retry_context =
        context
        |> put_signed_request(fresh_sr)
        |> maybe_drop_legacy_signed_request(fresh_sr)
        |> then(fn ctx ->
          if is_binary(request_id) do
            Map.put(ctx, :approved_invocation, %{
              request_id: request_id,
              principal_id: agent_id,
              resource_uri: resource,
              decision: :approved
            })
          else
            ctx
          end
        end)
        |> Map.put(:allow_pipeline_internal, true)

      runner =
        Application.get_env(
          :arbor_actions,
          :reviewed_validation_nested_runner,
          &Actions.authorize_and_execute/4
        )

      case runner.(agent_id, module, nested_params, retry_context) do
        {:ok, result} when is_map(result) and not is_struct(result) ->
          merge_nested_success(result, request_id, note, profile_id)

        {:ok, :pending_approval, retry_id} ->
          {:error, "still requires approval after grant: #{retry_id}"}

        {:ok, _non_map} ->
          # Fail closed — never project unbounded inspect/binary leftovers.
          {:error, :nested_validation_result_not_map}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "approved validation failed: #{inspect(reason)}"}
      end
    end
  end

  defp merge_nested_success(result, request_id, note, profile_id)
       when is_map(result) and not is_struct(result) do
    base = %{
      "interaction_outcome" => "",
      "request_id" => request_id || "",
      "note" => note || ""
    }

    case project_nested_result(result, profile_id) do
      {:ok, nested} -> {:ok, Map.merge(nested, base)}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp project_nested_result(result, "contract_change") do
    {files, rest} = pop_inventory(result, :changed_files)
    {tests, rest} = pop_inventory(rest, :test_paths)

    with {:ok, inventories} <- ContractChangeCore.admit_transport_inventories(files, tests) do
      nested = json_clean_object(rest)

      {:ok,
       nested
       |> Map.put("changed_files", inventories.changed_files)
       |> Map.put("test_paths", inventories.test_paths)}
    else
      {:error, :too_many_paths} -> {:error, :nested_contract_inventory_exceeds_bound}
      {:error, _} = error -> error
    end
  end

  defp project_nested_result(result, _profile_id), do: {:ok, json_clean_object(result)}

  defp pop_inventory(result, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      is_map_key(result, key) ->
        {inventory_or_empty(Map.get(result, key)), Map.delete(result, key)}

      is_map_key(result, string_key) ->
        {inventory_or_empty(Map.get(result, string_key)), Map.delete(result, string_key)}

      true ->
        {[], result}
    end
  end

  defp inventory_or_empty(value) when is_list(value), do: value
  defp inventory_or_empty(_value), do: :invalid_inventory

  defp json_clean_object(result) when is_map(result) and not is_struct(result) do
    Enum.reduce(result, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k

      if is_binary(key) do
        Map.put(acc, key, json_clean_value(v))
      else
        acc
      end
    end)
  end

  defp control_payload(outcome, request_id, note)
       when outcome in ["denied", "rework"] and is_binary(request_id) do
    {:ok, bounded_note} =
      ApprovalAnswer.validate_note(note, drop_invalid: true, truncate: true)

    %{
      "interaction_outcome" => outcome,
      "request_id" => request_id,
      "note" => bounded_note
    }
  end

  # -- signing (mirrors ReviewedCommit) --------------------------------------

  defp fresh_signed_request(resource, context) when is_binary(resource) do
    case signing_authority(context) do
      {:ok, authority} ->
        case Arbor.Security.sign_with_authority(authority, resource) do
          {:ok, signed} -> {:ok, signed}
          {:error, reason} -> {:error, {:signing_failed, reason}}
        end

      {:error, _} = err ->
        case legacy_signer(context) do
          signer when is_function(signer, 1) ->
            case signer.(resource) do
              {:ok, signed} -> {:ok, signed}
              {:error, reason} -> {:error, {:signing_failed, reason}}
              other -> {:error, {:signing_failed, other}}
            end

          _ ->
            err
        end
    end
  end

  defp signing_authority(context) do
    authority =
      Map.get(context, :signing_authority) ||
        nested_opt(context, :signing_authority)

    cond do
      SigningAuthority.signing_authority?(authority) ->
        {:ok, authority}

      is_map(authority) ->
        case SigningAuthority.canonicalize(authority) do
          {:ok, canonical} -> {:ok, canonical}
          {:error, reason} -> {:error, {:invalid_signing_authority, reason}}
        end

      true ->
        {:error, :missing_signing_authority}
    end
  end

  defp legacy_signer(context) do
    auth_context_signer =
      case Map.get(context, :auth_context) do
        %{signer: signer} when is_function(signer, 1) -> signer
        _ -> nil
      end

    direct_signer = Map.get(context, :signer)

    cond do
      is_function(auth_context_signer, 1) -> auth_context_signer
      not is_nil(direct_signer) -> direct_signer
      true -> nested_opt(context, :signer)
    end
  end

  defp nested_opt(context, key) do
    case Map.get(context, :nested_engine_opts) do
      opts when is_list(opts) -> Keyword.get(opts, key)
      _ -> nil
    end
  end

  defp put_signed_request(context, signed_request) do
    context
    |> Map.put(:signed_request, signed_request)
    |> Map.put(:identity_verified, false)
    |> then(fn ctx ->
      case Map.get(ctx, :auth_context) do
        %{__struct__: _} = auth ->
          Map.put(ctx, :auth_context, %{auth | signed_request: signed_request})

        auth when is_map(auth) ->
          Map.put(ctx, :auth_context, Map.put(auth, :signed_request, signed_request))

        _ ->
          ctx
      end
    end)
  end

  defp maybe_drop_legacy_signed_request(context, signed_request)
       when is_map(context) and is_map(signed_request) do
    if not match?(%SignedRequest{}, signed_request) and
         not Arbor.Security.Config.identity_verification_enabled?() do
      context
      |> Map.delete(:signed_request)
      |> Map.delete("signed_request")
      |> clear_auth_context_signed_request()
    else
      context
    end
  end

  defp maybe_drop_legacy_signed_request(context, _signed_request), do: context

  defp clear_auth_context_signed_request(context) do
    case Map.get(context, :auth_context) || Map.get(context, "auth_context") do
      %AuthContext{} = auth_context ->
        Map.put(context, :auth_context, %{auth_context | signed_request: nil})

      auth_context when is_map(auth_context) ->
        Map.put(
          context,
          :auth_context,
          auth_context
          |> Map.delete(:signed_request)
          |> Map.delete("signed_request")
        )

      _ ->
        context
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Approval wait is owner/context-owned. Params `timeout` / `stage_timeout` are
  # the nested validator deadline bindings (ExecHandler-clamped) and must never
  # widen or replace the approval ceiling.
  defp approval_timeout(_params, context) do
    case context_value(context, :approval_timeout_ms) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      nil -> {:ok, configured_approval_timeout()}
      _ -> {:error, :invalid_approval_timeout}
    end
  end

  defp configured_approval_timeout do
    configured =
      Application.get_env(
        :arbor_actions,
        :approval_timeout_ms,
        Application.get_env(
          :arbor_orchestrator,
          :approval_timeout_ms,
          @default_approval_timeout
        )
      )

    case configured do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_approval_timeout
    end
  end

  defp interaction_request?(id) when is_binary(id), do: String.starts_with?(id, "irq")
  defp interaction_request?(_), do: false

  defp context_agent_id(context) do
    context_value(context, :agent_id) ||
      case Map.get(context, :auth_context) do
        %{agent_id: id} when is_binary(id) -> id
        %{principal_id: id} when is_binary(id) -> id
        _ -> nil
      end
  end

  defp context_value(context, key) when is_atom(key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end

  defp param_string(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp json_clean_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_clean_value(v) when is_atom(v), do: Atom.to_string(v)

  defp json_clean_value(v) when is_list(v) do
    # Bound nested lists; drop non-JSON-clean members rather than inspect/1.
    v
    |> Enum.take(64)
    |> Enum.map(&json_clean_value/1)
    |> Enum.reject(&(&1 == :drop))
  end

  defp json_clean_value(v) when is_map(v) and not is_struct(v) do
    v
    |> Enum.take(64)
    |> Enum.reduce(%{}, fn {k, val}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k

      if is_binary(key) and byte_size(key) <= 256 do
        cleaned = json_clean_value(val)
        if cleaned == :drop, do: acc, else: Map.put(acc, key, cleaned)
      else
        acc
      end
    end)
  end

  # Non-JSON leaves are dropped (not inspected) so hostile terms cannot expand
  # into unbounded Engine context strings.
  defp json_clean_value(_v), do: :drop

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
