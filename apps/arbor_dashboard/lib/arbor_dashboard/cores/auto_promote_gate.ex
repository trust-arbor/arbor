defmodule Arbor.Dashboard.Cores.AutoPromoteGate do
  @moduledoc """
  H13 security gate for the "Always Allow" trust-profile mutation.

  The dashboard's always-allow flow calls `Trust.Store.always_allow/2`, which
  permanently sets the agent's trust profile to `:auto` for a resource. Without
  a capability check, any actor that can click "Always Allow" could silently
  escalate any agent's trust on any resource. The H13 fix gates the mutation
  behind the `arbor://trust/auto_promote/<target_agent_id>` capability.

  This module is the single source of truth for the gate. It is used by both
  `ChatLive` (the user-facing approval surface) and was previously inlined in
  `ConsensusLive`. Extracted so the gate fires on every code path that can
  trigger always-allow.

  ## Shape

  - `authorize/2` is the impure shell — resolves the actor, calls
    `Arbor.Security.authorize/3`, and routes the result through `decision/1`.
  - `decision/1` is the pure decision function. Any non-`:authorized` result
    denies. This is what the H13 regression test pins, so future drift in
    `Security.authorize/3`'s return shape doesn't silently re-open the gate.
  """

  require Logger

  @doc """
  Authorize the auto-promote mutation for `actor_id` on `target_agent_id`.

  Returns `:ok` only when the actor holds the per-target auto-promote
  capability. The `"system"` actor (dev/test path with no OIDC session) is
  always denied — auto-promote is never appropriate to grant to the implicit
  caller from a UI surface.
  """
  @spec authorize(String.t() | nil, String.t()) ::
          :ok | {:error, :unauthorized_auto_promote}
  def authorize(actor_id, target_agent_id) when is_binary(target_agent_id) do
    resource = "arbor://trust/auto_promote/#{target_agent_id}"

    decision =
      cond do
        actor_id in [nil, "", "system"] ->
          {:error, :no_actor}

        true ->
          try do
            Arbor.Security.authorize(actor_id, resource, :write)
          rescue
            _ -> {:error, :security_unavailable}
          catch
            :exit, _ -> {:error, :security_unavailable}
          end
      end

    decision(decision)
  end

  @doc """
  Pure decision function. Public so regression tests can pin every non-OK
  AuthDecision / Security.authorize result shape to the deny outcome without
  needing the full Security runtime.
  """
  @spec decision(term()) :: :ok | {:error, :unauthorized_auto_promote}
  def decision({:ok, :authorized}), do: :ok
  def decision(:authorized), do: :ok
  def decision(_), do: {:error, :unauthorized_auto_promote}
end
