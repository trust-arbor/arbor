defmodule Arbor.Actions.TaintEnforcement do
  @moduledoc """
  Enforces taint policies on action parameters before execution.

  Checks whether action parameters comply with the taint policy from the
  execution context. When `context[:param_taint]` is present, each parameter is
  checked against its own provenance label. The aggregate `context[:taint]`
  remains the backward-compatible fallback and operation-level label. Three
  policy modes are supported:

  - `:permissive` (default) — uses standard `Taint.check_params/3`, allows derived data
  - `:audit_only` — logs violations but never blocks execution
  - `:strict` — blocks any non-trusted taint on control parameters

  After execution, emits taint propagation signals so downstream consumers
  know the output taint level.
  """

  alias Arbor.Actions.Taint
  alias Arbor.Actions.TaintEvents

  @doc """
  Check if action parameters comply with taint policy.

  Returns `:ok` if execution should proceed,
  `{:error, {:taint_blocked, param, level, role}}` if blocked.
  """
  @spec check(module(), map(), map() | nil) :: :ok | {:error, term()}
  def check(action_module, params, context) do
    case extract_param_taint(context) do
      {:ok, param_taint} ->
        policy = Map.get(context, :taint_policy, :permissive)
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
    case extract_taint_context(context) do
      nil ->
        # No taint metadata — backward compatible, allow execution
        :ok

      %{taint: nil} ->
        # Taint context exists but no taint level — allow execution
        :ok

      %{taint: taint_level} ->
        policy = Map.get(context, :taint_policy, :permissive)
        check_with_policy(action_module, params, taint_level, policy, context)
    end
  end

  # A present map, including an empty map, selects per-parameter enforcement.
  # The aggregate label must not contaminate parameters omitted from this map.
  defp extract_param_taint(nil), do: :none
  defp extract_param_taint(context) when not is_map(context), do: :none

  defp extract_param_taint(context) do
    nested_context = Map.get(context, :taint_context)

    cond do
      is_map(Map.get(context, :param_taint)) ->
        {:ok, Map.fetch!(context, :param_taint)}

      is_map(nested_context) and is_map(Map.get(nested_context, :param_taint)) ->
        {:ok, Map.fetch!(nested_context, :param_taint)}

      true ->
        :none
    end
  end

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
    end
  end

  defp check_with_policy(action_module, params, taint_level, :strict, _context) do
    # Strict: block derived, untrusted, hostile on control params
    # Only trusted is allowed for control parameters
    if taint_level == :trusted do
      :ok
    else
      roles = Taint.roles_for(action_module)
      check_strict_taint(params, roles, taint_level)
    end
  end

  defp check_with_policy(action_module, params, taint_level, _permissive, context) do
    # Permissive (default): use standard check from Taint module
    # This blocks untrusted/hostile on control, but allows derived
    case Taint.check_params(action_module, params, %{taint: taint_level}) do
      :ok ->
        # If derived was used on control params, emit audit signal
        if taint_level == :derived do
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
          {:cont, :ok}

        {:ok, taint} ->
          role = Map.get(roles, param_name, :data)

          result =
            if control_role?(role) and taint_level(taint) != :trusted do
              {:error, {:taint_blocked, param_name, taint_level(taint), :control}}
            else
              Taint.check_params(action_module, %{param_name => value}, %{taint: taint})
            end

          case result do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        :error ->
          {:cont, :ok}
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

  # Strict mode: any non-trusted taint on control params is blocked
  defp check_strict_taint(params, roles, taint_level) do
    # Find first control param (under strict, any non-trusted is blocked)
    violation =
      Enum.find_value(params, fn {param_name, _value} ->
        role = Map.get(roles, param_name, :data)

        if role == :control do
          {:taint_blocked, param_name, taint_level, :control}
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
      if Map.get(roles, param_name) == :control do
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
