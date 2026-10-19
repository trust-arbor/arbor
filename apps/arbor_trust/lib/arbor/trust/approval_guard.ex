defmodule Arbor.Trust.ApprovalGuard do
  @moduledoc """
  Trust-policy approval gate for authorized capabilities.

  This module lives in the policy layer. It decides whether a capability the
  principal already holds may run automatically, must be escalated, or is denied
  by the current trust profile.
  """

  alias Arbor.Security.Escalation
  alias Arbor.Trust.ApprovalContext
  alias Arbor.Trust.Config

  require Logger

  # Security regression (2026-10-11 cross-library review F-015): this list is a
  # FLOOR. A resolved `:auto` mode (e.g. from an operator `security_ceilings`
  # override) must still be gated for these classes, and the match is
  # segment-aware so `arbor://shellx` does not inherit the lock. Trust
  # mutation joins the list: it is the only path by which an agent could
  # raise its own autonomy, so it must never be unattended.
  @always_locked_uri_classes [
    "arbor://shell",
    "arbor://governance",
    "arbor://code/hot_load",
    "arbor://trust/write",
    "arbor://trust/auto_promote"
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

  @doc false
  def check_notice_publication(capability, principal_id, resource_uri) do
    # Same confirmation and ceiling decision as the ordinary guard, without
    # private payload-bearing proposal, log or approval signal emission. This
    # finite mailbox feature has no human approval route yet.
    policy = Config.policy_module()

    mode =
      if Code.ensure_loaded?(policy) and
           function_exported?(policy, :notice_confirmation_mode, 2),
         do: apply(policy, :notice_confirmation_mode, [principal_id, resource_uri]),
         else: :deny

    cond do
      mode == :deny -> {:error, :policy_denied}
      approval_required?(capability) -> {:error, :notice_approval_required}
      mode == :auto -> :ok
      mode == :gated and pre_approved_bypasses_ceiling?(capability, resource_uri) -> :ok
      true -> {:error, :notice_approval_required}
    end
  rescue
    _ -> {:error, :policy_denied}
  catch
    _, _ -> {:error, :policy_denied}
  end

  defp check_with_policy(capability, principal_id, resource_uri, opts) do
    mode = get_confirmation_mode(principal_id, resource_uri, opts)

    # Floor: an always-locked class can never resolve to unattended `:auto`,
    # whatever the profile or an operator ceiling override says (F-015).
    mode = if mode == :auto and always_locked?(resource_uri), do: :gated, else: mode

    case mode do
      :auto ->
        cond do
          approved_invocation?(principal_id, resource_uri, opts) ->
            :ok

          approval_required?(capability) ->
            Escalation.maybe_escalate(
              capability,
              principal_id,
              resource_uri,
              escalation_opts(
                opts,
                :capability_constraint,
                :capability_requires_approval,
                principal_id,
                resource_uri
              )
            )

          true ->
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
              escalation_opts(
                opts,
                :capability_constraint,
                :capability_requires_approval,
                principal_id,
                resource_uri
              )
            )

          pre_approved_bypasses_ceiling?(capability, resource_uri) ->
            :ok

          true ->
            capability
            |> require_approval()
            |> Escalation.maybe_escalate(
              principal_id,
              resource_uri,
              escalation_opts(opts, :trust_policy, :policy_gated, principal_id, resource_uri)
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
    confirmation_mode_for(principal_id, resource_uri, opts, true)
  end

  defp confirmation_mode_for(principal_id, resource_uri, opts, report?) do
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
        if report?, do: warn_trust_unavailable(principal_id, resource_uri, :not_loaded)
        :gated
    end
  rescue
    e ->
      if report?, do: warn_trust_unavailable(principal_id, resource_uri, {:raised, e})
      :gated
  catch
    :exit, reason ->
      if report?, do: warn_trust_unavailable(principal_id, resource_uri, {:exit, reason})
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

  # Attach the trust-side explanation (matched rule, ceiling, capability
  # risk profile) so the human prompt can say *why* it is asking and *what is
  # at stake*. Display-only; the decision above was already made.
  defp escalation_opts(opts, gate, reason, principal_id, resource_uri) do
    opts
    |> Keyword.put_new(:gate, gate)
    |> Keyword.put_new(:reason, reason)
    |> Keyword.put_new_lazy(:trust_context, fn ->
      ApprovalContext.build(principal_id, resource_uri, opts)
    end)
  end

  defp approval_required?(capability) do
    constraints = capability.constraints || %{}

    constraints[:requires_approval] == true or
      constraints["requires_approval"] == true
  end

  defp approved_invocation?(principal_id, resource_uri, opts) do
    receipt = opt(opts, :approved_invocation)
    digest = opt(opts, :argument_digest)
    action = receipt_action(opts)
    request_id = incoming_request_id(opts, receipt)

    is_map(receipt) and is_binary(digest) and
      Arbor.Security.confirm_consumed_approval_receipt(
        receipt,
        principal_id,
        resource_uri,
        action,
        digest,
        request_id
      ) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Receipts are bound to an atom (`:execute`). `:approval_action` is the
  # human-facing operation name (`"file.write"`) and must not retarget the
  # receipt. An explicit `:receipt_action` wins; an atom `:approval_action`
  # still works for callers that have not split the keys.
  defp receipt_action(opts) do
    case opt(opts, :receipt_action) do
      action when is_atom(action) and not is_nil(action) ->
        action

      _ ->
        case opt(opts, :approval_action) do
          action when is_atom(action) and not is_nil(action) -> action
          _ -> :execute
        end
    end
  end

  defp incoming_request_id(opts, receipt) do
    case opt(opts, :request_id) do
      request_id when is_binary(request_id) -> request_id
      nil -> receipt_request_id(receipt)
      _invalid -> ""
    end
  end

  defp receipt_request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id

  defp receipt_request_id(%{"request_id" => request_id}) when is_binary(request_id),
    do: request_id

  defp receipt_request_id(_receipt), do: ""

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
    Enum.any?(@always_locked_uri_classes, fn class ->
      uri == class or Arbor.Contracts.Security.CapabilityUri.prefix_match?(class, uri)
    end)
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
