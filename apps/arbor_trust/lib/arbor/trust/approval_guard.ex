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
  @spec check(map(), String.t(), String.t(), keyword()) ::
          :ok | {:ok, :pending_approval, String.t()} | {:error, term()}
  def check(capability, principal_id, resource_uri, opts \\ []) do
    if enabled?() do
      check_with_policy(capability, principal_id, resource_uri, opts)
    else
      Escalation.maybe_escalate(capability, principal_id, resource_uri, opts)
    end
  end

  @doc "Whether trust-policy approval gating is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.approval_guard_enabled?()

  defp check_with_policy(capability, principal_id, resource_uri, opts) do
    case get_confirmation_mode(principal_id, resource_uri, opts) do
      :auto ->
        if approval_required?(capability) do
          Escalation.maybe_escalate(
            capability,
            principal_id,
            resource_uri,
            escalation_opts(opts, :capability_constraint, :capability_requires_approval)
          )
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
          approved_invocation?(principal_id, resource_uri, opts) ->
            :ok

          approval_required?(capability) ->
            Escalation.maybe_escalate(
              capability,
              principal_id,
              resource_uri,
              escalation_opts(opts, :capability_constraint, :capability_requires_approval)
            )

          pre_approved_bypasses_ceiling?(capability, resource_uri) ->
            :ok

          true ->
            capability
            |> require_approval()
            |> Escalation.maybe_escalate(
              principal_id,
              resource_uri,
              escalation_opts(opts, :trust_policy, :policy_gated)
            )
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

  defp get_confirmation_mode(principal_id, resource_uri, opts) do
    policy = Config.policy_module()

    cond do
      Code.ensure_loaded?(policy) and function_exported?(policy, :confirmation_mode, 3) ->
        apply(policy, :confirmation_mode, [principal_id, resource_uri, opts])

      Code.ensure_loaded?(policy) and function_exported?(policy, :effective_mode, 3) ->
        policy
        |> apply(:effective_mode, [principal_id, resource_uri, opts])
        |> mode_to_confirmation()

      Code.ensure_loaded?(policy) and function_exported?(policy, :confirmation_mode, 2) ->
        apply(policy, :confirmation_mode, [principal_id, resource_uri])

      true ->
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

  defp mode_to_confirmation(:block), do: :deny
  defp mode_to_confirmation(:ask), do: :gated
  defp mode_to_confirmation(:allow), do: :auto
  defp mode_to_confirmation(:auto), do: :auto
  defp mode_to_confirmation(_mode), do: :gated

  defp require_approval(capability) do
    %{capability | constraints: Map.put(capability.constraints || %{}, :requires_approval, true)}
  end

  defp escalation_opts(opts, gate, reason) do
    opts
    |> Keyword.put_new(:gate, gate)
    |> Keyword.put_new(:reason, reason)
  end

  defp approval_required?(capability) do
    constraints = capability.constraints || %{}

    constraints[:requires_approval] == true or
      constraints["requires_approval"] == true
  end

  defp approved_invocation?(principal_id, resource_uri, opts) do
    case opt(opts, :approved_invocation) do
      approval when is_map(approval) ->
        approval_field(approval, :principal_id) == principal_id and
          approval_field(approval, :resource_uri) == resource_uri and
          approval_field(approval, :decision) in [:approved, :approve, "approved", "approve"] and
          is_binary(approval_field(approval, :request_id))

      _ ->
        false
    end
  end

  defp approval_field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp opt(opts, key) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        string_key = Atom.to_string(key)

        case List.keyfind(opts, string_key, 0) do
          {^string_key, value} -> value
          _ -> nil
        end
    end
  end

  defp opt(opts, key) when is_map(opts) do
    case Map.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(opts, Atom.to_string(key))
    end
  end

  defp opt(_opts, _key), do: nil

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
