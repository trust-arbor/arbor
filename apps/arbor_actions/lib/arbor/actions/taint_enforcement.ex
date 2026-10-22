defmodule Arbor.Actions.TaintEnforcement do
  @moduledoc """
  Enforces taint policies on action parameters before execution.

  Checks whether action parameters comply with the taint policy from the
  execution context. When `context[:param_taint]` is present, each parameter is
  checked against its own provenance label. The aggregate `context[:taint]`
  remains the backward-compatible fallback and operation-level label. Three
  policy modes are supported:

  - `:permissive` — uses standard `Taint.check_params/3`, allows derived data
  - `:audit_only` — logs violations but never blocks execution
  - `:strict` — blocks any non-trusted taint on control parameters

  When `context` omits `:taint_policy`, the check uses `configured_policy/0`
  (application env, never a hard-coded `:permissive` fallback). Missing or
  invalid env fails closed to `:strict` in production and `:audit_only`
  otherwise.

  Resolved policy is the requested context policy raised to any floor:
  an explicit `Capability.taint_policy/1` constraint, and in production
  the configured default. A context `:permissive` cannot weaken `:strict`.

  Under `:strict`, a `:control` param with a nil, missing, or empty label
  is treated as `:untrusted`. An empty `:param_taint` map does not hide
  the aggregate label.

  After execution, emits taint propagation signals so downstream consumers
  know the output taint level.
  """

  alias Arbor.Actions.Taint
  alias Arbor.Actions.TaintEvents
  alias Arbor.Contracts.Security.Capability

  @policies [:strict, :permissive, :audit_only]
  @policy_rank %{audit_only: 0, permissive: 1, strict: 2}

  @doc """
  Configured default taint policy.

  Reads `:arbor_actions, :default_taint_policy`. A missing or invalid value
  fails closed to `:strict` when the runtime is production, otherwise
  `:audit_only` (the committed dev default). Never falls back to
  `:permissive`.
  """
  @spec configured_policy() :: :strict | :permissive | :audit_only
  @spec configured_policy(keyword()) :: :strict | :permissive | :audit_only
  def configured_policy(opts \\ []) when is_list(opts) do
    case Application.fetch_env(:arbor_actions, :default_taint_policy) do
      {:ok, policy} when policy in @policies ->
        policy

      _ ->
        env = Keyword.get(opts, :env) || runtime_env()
        if env == :prod, do: :strict, else: :audit_only
    end
  end

  @doc """
  Resolve the effective taint policy for an execution context.

  Starts from a valid `context[:taint_policy]` or `configured_policy/1`.
  Raises that value to the most restrictive floor among:

  - an explicit `Capability.taint_policy/1` on `context[:capability]`
    (absent constraint is not a floor — the contract default
    `:permissive` must not block `:audit_only`)
  - in production, `configured_policy/1`
  """
  @spec resolve_policy(map() | nil) :: :strict | :permissive | :audit_only
  @spec resolve_policy(map() | nil, keyword()) :: :strict | :permissive | :audit_only
  def resolve_policy(context, opts \\ []) when is_list(opts) do
    requested = requested_policy(context)
    floors = policy_floors(context, opts)
    Enum.reduce(floors, requested, &raise_to_floor/2)
  end

  @doc """
  Check if action parameters comply with taint policy.

  Returns `:ok` if execution should proceed,
  `{:error, {:taint_blocked, param, level, role}}` if blocked.
  """
  @spec check(module(), map(), map() | nil) :: :ok | {:error, term()}
  def check(action_module, params, context) do
    case extract_param_taint(context) do
      {:ok, param_taint} ->
        policy = policy_from_context(context)
        check_param_taint_with_policy(action_module, params, param_taint, policy, context)

      :none ->
        check_legacy_aggregate(action_module, params, context)
    end
  end

  @doc """
  After successful execution, emit taint propagation signal if context had taint.
  """
  @spec maybe_emit_propagated(module(), map() | nil, {:ok, term()} | {:error, term()}) :: :ok
  def maybe_emit_propagated(action_module, context, {:ok, _result}) do
    input_taint = extract_taint_level(context)

    if input_taint do
      # context[:taint] may be either a bare level atom OR a full Taint struct
      # (the orchestrator threads `Context.worst_taint/2`, which returns a
      # %Taint{} struct). `Arbor.Signals.Taint.propagate/1` is the atom-level
      # API and crashes on a struct, so normalize to the level first — mirrors
      # what `Taint.check_params` does internally via extract_level/1.
      input_level = taint_level(input_taint)
      output_taint = Arbor.Signals.Taint.propagate([input_level])
      TaintEvents.emit_taint_propagated(action_module, input_level, output_taint, context)
    else
      :ok
    end
  end

  def maybe_emit_propagated(_action_module, _context, _error_result), do: :ok

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp check_legacy_aggregate(action_module, params, context) do
    policy = policy_from_context(context)

    case extract_taint_context(context) do
      %{taint: taint_level} when not is_nil(taint_level) ->
        check_with_policy(action_module, params, taint_level, policy, context)

      _missing ->
        # No usable aggregate label. Under :strict an unlabeled control
        # param is untrusted; otherwise keep the pre-strict allow.
        maybe_deny_unlabeled_legacy(action_module, params, policy)
    end
  end

  defp maybe_deny_unlabeled_legacy(action_module, params, :strict) do
    check_strict_taint(params, Taint.roles_for(action_module), :untrusted)
  end

  defp maybe_deny_unlabeled_legacy(_action_module, _params, _policy), do: :ok

  defp policy_from_context(context), do: resolve_policy(context)

  defp requested_policy(context) when is_map(context) do
    case Map.fetch(context, :taint_policy) do
      {:ok, policy} when policy in @policies -> policy
      _ -> configured_policy()
    end
  end

  defp requested_policy(_context), do: configured_policy()

  defp policy_floors(context, opts) do
    env = Keyword.get(opts, :env) || runtime_env()

    []
    |> maybe_put_floor(capability_policy_floor(context))
    |> maybe_put_configured_prod_floor(env, opts)
  end

  defp maybe_put_floor(floors, {:ok, policy}) when policy in @policies, do: [policy | floors]
  defp maybe_put_floor(floors, _none), do: floors

  defp maybe_put_configured_prod_floor(floors, :prod, opts),
    do: [configured_policy(opts) | floors]

  defp maybe_put_configured_prod_floor(floors, _env, _opts), do: floors

  defp raise_to_floor(floor, current) do
    if Map.fetch!(@policy_rank, floor) > Map.fetch!(@policy_rank, current) do
      floor
    else
      current
    end
  end

  defp capability_policy_floor(context) when is_map(context) do
    explicit_capability_policy(Map.get(context, :capability))
  end

  defp capability_policy_floor(_context), do: :none

  # Capability.taint_policy/1 defaults to :permissive when the constraint is
  # absent. That default is not a floor — applying it would raise :audit_only
  # on every ordinary grant. Only an explicit constraint is load-bearing.
  @doc false
  @spec explicit_capability_policy(term()) :: {:ok, :strict | :permissive | :audit_only} | :none
  def explicit_capability_policy(%Capability{constraints: constraints} = cap)
      when is_map(constraints) do
    if Map.has_key?(constraints, :taint_policy) or Map.has_key?(constraints, "taint_policy") do
      {:ok, Capability.taint_policy(cap)}
    else
      :none
    end
  end

  def explicit_capability_policy(_cap), do: :none

  defp runtime_env do
    case Application.get_env(:arbor_actions, :taint_policy_runtime_env) do
      env when env in [:prod, :dev, :test] ->
        env

      _ ->
        case System.get_env("MIX_ENV") do
          "prod" ->
            :prod

          "dev" ->
            :dev

          "test" ->
            :test

          _ ->
            if function_exported?(Mix, :env, 0), do: Mix.env(), else: :prod
        end
    end
  end

  # A non-empty map selects per-parameter enforcement. An empty map must not
  # hide the aggregate label — fall through to the legacy path.
  defp extract_param_taint(nil), do: :none
  defp extract_param_taint(context) when not is_map(context), do: :none

  defp extract_param_taint(context) do
    nested_context = Map.get(context, :taint_context)

    cond do
      nonempty_param_taint?(Map.get(context, :param_taint)) ->
        {:ok, Map.fetch!(context, :param_taint)}

      is_map(nested_context) and nonempty_param_taint?(Map.get(nested_context, :param_taint)) ->
        {:ok, Map.fetch!(nested_context, :param_taint)}

      true ->
        :none
    end
  end

  defp nonempty_param_taint?(map) when is_map(map) and map_size(map) > 0, do: true
  defp nonempty_param_taint?(_), do: false

  # Extract taint context from the context map.
  # Looks for :taint key directly or in :taint_context sub-map.
  defp extract_taint_context(nil), do: nil
  defp extract_taint_context(context) when not is_map(context), do: nil

  defp extract_taint_context(context) do
    cond do
      Map.has_key?(context, :taint) ->
        %{taint: Map.get(context, :taint)}

      Map.has_key?(context, :taint_context) and is_map(context.taint_context) ->
        context.taint_context

      true ->
        nil
    end
  end

  # Apply taint policy to parameter check.
  defp check_with_policy(action_module, params, taint_level, :audit_only, context) do
    # Audit-only: log violations but don't block
    case Taint.check_params(action_module, params, %{taint: taint_level}) do
      :ok ->
        :ok

      {:error, {:taint_blocked, param, level, _role}} ->
        # Log the violation but allow execution
        TaintEvents.emit_taint_audited(action_module, param, level, context)
        :ok

      # A sanitization-requiring control param (e.g. Shell's `command`) with a
      # non-trusted aggregate label. Audit it like the per-parameter path does;
      # this clause was missing, so audit-only raised CaseClauseError instead
      # (reachable once external-agent entry points labeled inputs :derived).
      {:error, {:missing_sanitization, param, _missing}} ->
        TaintEvents.emit_taint_audited(action_module, param, :unsanitized, context)
        :ok
    end
  end

  defp check_with_policy(action_module, params, taint, :strict, _context) do
    roles = Taint.roles_for(action_module)

    case check_strict_taint(params, roles, taint_level(taint)) do
      :ok -> Taint.check_params(action_module, params, %{taint: taint})
      error -> error
    end
  end

  defp check_with_policy(action_module, params, taint, _permissive, context) do
    # Permissive: use standard check from Taint module.
    # This blocks untrusted/hostile on control, but allows derived.
    # Not a missing-policy fallback — callers resolve policy via configured_policy/0.
    case Taint.check_params(action_module, params, %{taint: taint}) do
      :ok ->
        # If derived was used on control params, emit audit signal
        if taint_level(taint) == :derived do
          maybe_emit_derived_audit(action_module, params, context)
        end

        :ok

      error ->
        error
    end
  end

  defp check_param_taint_with_policy(action_module, params, param_taint, :audit_only, context) do
    Enum.each(params, fn {param_name, value} ->
      case fetch_param_taint(param_taint, param_name) do
        {:ok, nil} ->
          :ok

        {:ok, taint} ->
          case Taint.check_params(action_module, %{param_name => value}, %{taint: taint}) do
            :ok ->
              :ok

            {:error, {:taint_blocked, ^param_name, level, _role}} ->
              TaintEvents.emit_taint_audited(action_module, param_name, level, context)

            {:error, {:missing_sanitization, ^param_name, _missing}} ->
              TaintEvents.emit_taint_audited(action_module, param_name, :unsanitized, context)
          end

        :error ->
          :ok
      end
    end)

    :ok
  end

  defp check_param_taint_with_policy(action_module, params, param_taint, :strict, _context) do
    roles = Taint.roles_for(action_module)

    Enum.reduce_while(params, :ok, fn {param_name, value}, :ok ->
      case fetch_param_taint(param_taint, param_name) do
        {:ok, nil} ->
          halt_or_cont(unlabeled_strict_control(roles, param_name))

        {:ok, taint} ->
          role = Map.get(roles, param_name, :data)

          result =
            if control_role?(role) and taint_level(taint) != :trusted do
              {:error, {:taint_blocked, param_name, taint_level(taint), :control}}
            else
              Taint.check_params(action_module, %{param_name => value}, %{taint: taint})
            end

          halt_or_cont(result)

        :error ->
          halt_or_cont(unlabeled_strict_control(roles, param_name))
      end
    end)
  end

  defp check_param_taint_with_policy(
         action_module,
         params,
         param_taint,
         _permissive,
         context
       ) do
    roles = Taint.roles_for(action_module)

    Enum.reduce_while(params, :ok, fn {param_name, value}, :ok ->
      case fetch_param_taint(param_taint, param_name) do
        {:ok, nil} ->
          {:cont, :ok}

        {:ok, taint} ->
          case Taint.check_params(action_module, %{param_name => value}, %{taint: taint}) do
            :ok ->
              if taint_level(taint) == :derived and
                   control_role?(Map.get(roles, param_name, :data)) do
                TaintEvents.emit_taint_audited(
                  action_module,
                  param_name,
                  :derived,
                  context
                )
              end

              {:cont, :ok}

            error ->
              {:halt, error}
          end

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp unlabeled_strict_control(roles, param_name) do
    role = Map.get(roles, param_name, :data)

    if control_role?(role) do
      {:error, {:taint_blocked, param_name, :untrusted, :control}}
    else
      :ok
    end
  end

  defp halt_or_cont(:ok), do: {:cont, :ok}
  defp halt_or_cont(error), do: {:halt, error}

  # Strict mode: any non-trusted taint on control params is blocked
  defp check_strict_taint(params, roles, level) do
    violation =
      Enum.find_value(params, fn {param_name, _value} ->
        role = Map.get(roles, param_name, :data)

        if control_role?(role) and level != :trusted do
          {:taint_blocked, param_name, level, :control}
        else
          nil
        end
      end)

    case violation do
      nil -> :ok
      blocked -> {:error, blocked}
    end
  end

  # Emit audit signal for derived data used on control params (permissive mode)
  defp maybe_emit_derived_audit(action_module, params, context) do
    roles = Taint.roles_for(action_module)

    Enum.each(params, fn {param_name, _value} ->
      if control_role?(Map.get(roles, param_name, :data)) do
        TaintEvents.emit_taint_audited(action_module, param_name, :derived, context)
      end
    end)
  end

  defp fetch_param_taint(param_taint, param_name) do
    case Map.fetch(param_taint, param_name) do
      {:ok, _taint} = found ->
        found

      :error when is_atom(param_name) ->
        Map.fetch(param_taint, Atom.to_string(param_name))

      :error when is_binary(param_name) ->
        Enum.find_value(param_taint, :error, fn
          {key, taint} when is_atom(key) ->
            if Atom.to_string(key) == param_name, do: {:ok, taint}, else: false

          _entry ->
            false
        end)

      :error ->
        :error
    end
  end

  defp control_role?(:control), do: true
  defp control_role?({:control, _opts}), do: true
  defp control_role?(_role), do: false

  # Extract taint level from context, checking both flat and nested forms.
  defp extract_taint_level(nil), do: nil
  defp extract_taint_level(context) when not is_map(context), do: nil

  defp extract_taint_level(context) do
    Map.get(context, :taint) || get_in(context, [:taint_context, :taint])
  end

  # Normalize a taint value (bare level atom or %Taint{} struct) to its level
  # atom, so the atom-level Arbor.Signals.Taint API can consume it.
  defp taint_level(%{level: level}), do: level
  defp taint_level(level) when is_atom(level), do: level
  defp taint_level(_), do: :untrusted
end
