defmodule Arbor.Actions.TaintEvents do
  @moduledoc """
  Emit taint enforcement signals for the security audit trail.

  This module emits taint-related security signals when the action dispatcher
  blocks or audits tainted data. Signals are emitted with category `:security`
  so they persist to the EventLog via the dual-emit pattern.

  ## Event Types

  | Event Type | Purpose |
  |------------|---------|
  | `:taint_blocked` | Untrusted/hostile data blocked from control parameter |
  | `:taint_propagated` | Taint context propagated through action execution |
  | `:taint_reduced` | Taint level reduced (e.g., via human review) |
  | `:taint_audited` | Derived data used in control param (permissive policy) |

  ## Usage

  These functions are called by the action dispatcher during taint enforcement:

      # When a control param is blocked due to taint
      TaintEvents.emit_taint_blocked(
        Arbor.Actions.Shell.Execute,
        :command,
        :untrusted,
        :control,
        context
      )

      # After successful execution with tainted input
      TaintEvents.emit_taint_propagated(
        Arbor.Actions.Shell.Execute,
        :untrusted,
        :derived,
        context
      )
  """

  alias Arbor.Signals

  @doc """
  Emit a signal when tainted data is blocked from a control parameter.

  This is called when the dispatcher blocks action execution because an
  untrusted, hostile, or (under strict policy) derived value was provided
  for a control parameter.

  The actual value is never logged to avoid exposing potentially malicious content.
  """
  @spec emit_taint_blocked(module(), atom(), atom(), atom(), map()) :: :ok
  def emit_taint_blocked(action_module, param, taint_level, role, context) do
    data = %{
      action: action_module_to_string(action_module),
      parameter: to_string(param),
      parameter_role: role,
      taint_level: taint_level,
      taint_source: get_in_context(context, :taint_source),
      agent_id: Map.get(context, :agent_id),
      taint_policy: Map.get(context, :taint_policy, :permissive),
      blocked_value_preview: nil
    }

    if function_exported?(Signals, :durable_emit, 4) do
      Signals.durable_emit(:security, :taint_blocked, data, stream_id: "security:events")
    else
      Signals.emit(:security, :taint_blocked, data)
    end
  end

  @doc """
  Emit a signal when taint is propagated through action execution.

  This is called after successful action execution when the context contained
  taint metadata, to record how taint flowed through the action.
  """
  @spec emit_taint_propagated(module(), atom(), atom(), map()) :: :ok
  def emit_taint_propagated(action_module, input_taint, output_taint, context) do
    Signals.emit(:security, :taint_propagated, %{
      action: action_module_to_string(action_module),
      input_taint: input_taint,
      output_taint: output_taint,
      taint_source: get_in_context(context, :taint_source),
      taint_chain: get_in_context(context, :taint_chain) || [],
      agent_id: Map.get(context, :agent_id)
    })
  end

  @doc """
  Emit a signal when taint level is intentionally reduced.

  This is called when taint is reduced through human review, consensus,
  or a verified pipeline.
  """
  @spec emit_taint_reduced(atom(), atom(), atom(), map()) :: :ok
  def emit_taint_reduced(from_level, to_level, reason, context) do
    data = %{
      from_level: from_level,
      to_level: to_level,
      reason: reason,
      agent_id: Map.get(context, :agent_id)
    }

    if function_exported?(Signals, :durable_emit, 4) do
      Signals.durable_emit(:security, :taint_reduced, data, stream_id: "security:events")
    else
      Signals.emit(:security, :taint_reduced, data)
    end
  end

  @doc """
  Emit a signal when derived data is used in a control parameter under permissive policy.

  Under permissive policy, derived data is allowed but should be audited.
  This signal records the usage without blocking execution.
  """
  @spec emit_taint_audited(module(), atom(), atom(), map()) :: :ok
  def emit_taint_audited(action_module, param, taint_level, context) do
    Signals.emit(:security, :taint_audited, %{
      action: action_module_to_string(action_module),
      parameter: to_string(param),
      taint_level: taint_level,
      taint_source: get_in_context(context, :taint_source),
      agent_id: Map.get(context, :agent_id),
      taint_policy: Map.get(context, :taint_policy, :permissive)
    })
  end

  @doc """
  Emit a signal when an action's egress crosses the trust boundary
  (2026-06-14 URI-addressing-vs-classification decision).

  Always emitted for external egress (`:external_provider` / `:external_peer`),
  regardless of whether the egress gate is enforcing — this is the observability
  that lets the gate land dark and gather data before enforcement is enabled.
  `intent` records what the gate *would* do (`:ask` / `:advise` / `:allow`).
  Never logs the egressed payload.
  """
  @spec emit_egress_observed(module(), atom(), atom(), map()) :: :ok
  def emit_egress_observed(action_module, egress_tier, intent, context) do
    data = %{
      action: action_module_to_string(action_module),
      egress_tier: egress_tier,
      gate_intent: intent,
      enforcing: Application.get_env(:arbor_security, :egress_gate_enforcing, false) == true,
      taint_level: extract_taint_level(get_in_context(context, :taint)),
      taint_source: get_in_context(context, :taint_source),
      agent_id: Map.get(context, :agent_id)
    }

    if function_exported?(Signals, :durable_emit, 4) do
      Signals.durable_emit(:security, :egress_observed, data, stream_id: "security:events")
    else
      Signals.emit(:security, :egress_observed, data)
    end
  end

  defp extract_taint_level(%{level: level}), do: level
  defp extract_taint_level(level) when is_atom(level), do: level
  defp extract_taint_level(_), do: nil

  # Convert action module to a loggable string
  defp action_module_to_string(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp action_module_to_string(module), do: inspect(module)

  # Safely extract a value from context, checking both top-level and :taint_context
  defp get_in_context(context, key) when is_map(context) do
    Map.get(context, key) || get_in(context, [:taint_context, key])
  end

  defp get_in_context(_, _), do: nil
end
