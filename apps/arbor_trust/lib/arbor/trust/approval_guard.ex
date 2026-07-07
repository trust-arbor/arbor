defmodule Arbor.Trust.ApprovalGuard do
  @moduledoc """
  Trust-policy approval gate for authorized capabilities.

  This module lives in the policy layer. It decides whether a capability the
  principal already holds may run automatically, must be escalated, or is denied
  by the current trust profile.
  """

  alias Arbor.Security.Escalation
  alias Arbor.Trust.Config

  require Logger

  @always_locked_uri_classes [
    "arbor://shell",
    "arbor://governance",
    "arbor://code/hot_load"
  ]

  @doc """
  Check whether a valid capability use is approved by trust policy.
  """
  @spec check(map(), String.t(), String.t()) ::
          :ok | {:ok, :pending_approval, String.t()} | {:error, term()}
  def check(capability, principal_id, resource_uri) do
    if enabled?() do
      check_with_policy(capability, principal_id, resource_uri)
    else
      Escalation.maybe_escalate(capability, principal_id, resource_uri)
    end
  end

  @doc "Whether trust-policy approval gating is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.approval_guard_enabled?()

  defp check_with_policy(capability, principal_id, resource_uri) do
    case get_confirmation_mode(principal_id, resource_uri) do
      :auto ->
        if approval_required?(capability) do
          Escalation.maybe_escalate(capability, principal_id, resource_uri)
        else
          safe_emit_signal(:approval_auto, %{
            principal_id: principal_id,
            resource_uri: resource_uri
          })

          :ok
        end

      :gated ->
        safe_emit_signal(:approval_gated, %{
          principal_id: principal_id,
          resource_uri: resource_uri
        })

        cond do
          approval_required?(capability) ->
            Escalation.maybe_escalate(capability, principal_id, resource_uri)

          pre_approved_bypasses_ceiling?(capability, resource_uri) ->
            :ok

          true ->
            capability
            |> require_approval()
            |> Escalation.maybe_escalate(principal_id, resource_uri)
        end

      :deny ->
        Logger.info("Policy denied access for #{principal_id} to #{resource_uri}",
          principal_id: principal_id,
          resource_uri: resource_uri
        )

        safe_emit_signal(:approval_denied, %{
          principal_id: principal_id,
          resource_uri: resource_uri
        })

        {:error, :policy_denied}
    end
  end

  defp get_confirmation_mode(principal_id, resource_uri) do
    policy = Config.policy_module()

    if Code.ensure_loaded?(policy) and
         function_exported?(policy, :confirmation_mode, 2) do
      apply(policy, :confirmation_mode, [principal_id, resource_uri])
    else
      warn_trust_unavailable(principal_id, resource_uri, :not_loaded)
      :gated
    end
  rescue
    e ->
      warn_trust_unavailable(principal_id, resource_uri, {:raised, e})
      :gated
  catch
    :exit, reason ->
      warn_trust_unavailable(principal_id, resource_uri, {:exit, reason})
      :gated
  end

  defp require_approval(capability) do
    %{capability | constraints: Map.put(capability.constraints || %{}, :requires_approval, true)}
  end

  defp approval_required?(capability) do
    capability.constraints[:requires_approval] == true or
      capability.constraints["requires_approval"] == true
  end

  defp pre_approved_bypasses_ceiling?(capability, requested_uri) do
    has_provenance?(capability) and
      uri_parameter_bounded?(capability.resource_uri) and
      not always_locked?(requested_uri)
  end

  defp has_provenance?(capability) do
    metadata = capability.metadata || %{}
    not is_nil(Map.get(metadata, :provenance) || Map.get(metadata, "provenance"))
  end

  defp uri_parameter_bounded?(uri) when is_binary(uri) do
    case String.split(uri, "/") do
      ["arbor:", "", _domain, _operation, leaf | _] when leaf not in ["**", "*"] -> true
      _ -> false
    end
  end

  defp uri_parameter_bounded?(_), do: false

  defp always_locked?(uri) when is_binary(uri) do
    Enum.any?(@always_locked_uri_classes, &String.starts_with?(uri, &1))
  end

  defp always_locked?(_), do: true

  defp warn_trust_unavailable(principal_id, resource_uri, cause) do
    Logger.warning(
      "ApprovalGuard: Trust.Policy unavailable (#{inspect(cause)}) — failing CLOSED to " <>
        ":gated for #{principal_id} -> #{resource_uri}",
      principal_id: principal_id,
      resource_uri: resource_uri
    )
  end

  defp safe_emit_signal(type, data) do
    Arbor.Signals.emit(:security, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
