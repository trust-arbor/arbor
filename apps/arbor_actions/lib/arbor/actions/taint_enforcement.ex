defmodule Arbor.Actions.TaintEnforcement do
  @moduledoc """
  Enforces taint policies on action parameters before execution.

  Checks whether action parameters comply with the taint policy from the
  execution context. Three policy modes are supported:

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
    taint_context = extract_taint_context(context)

    case taint_context do
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

  @doc """
  After successful execution, emit taint propagation signal if context had taint.
  """
  @spec maybe_emit_propagated(module(), map() | nil, {:ok, term()} | {:error, term()}) :: :ok
  def maybe_emit_propagated(action_module, context, {:ok, _result}) do
    input_taint = extract_taint_level(context)

    if input_taint do
      output_taint = Arbor.Signals.Taint.propagate([input_taint])
      TaintEvents.emit_taint_propagated(action_module, input_taint, output_taint, context)
    else
      :ok
    end
  end

  def maybe_emit_propagated(_action_module, _context, _error_result), do: :ok

  # ============================================================================
  # Private Helpers
  # ============================================================================

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

  # Extract taint level from context, checking both flat and nested forms.
  defp extract_taint_level(nil), do: nil
  defp extract_taint_level(context) when not is_map(context), do: nil

  defp extract_taint_level(context) do
    Map.get(context, :taint) || get_in(context, [:taint_context, :taint])
  end
end
