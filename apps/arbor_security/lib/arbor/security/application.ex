defmodule Arbor.Security.Application do
  @moduledoc false

  use Application

  alias Arbor.Security.ProviderGate

  @compile_env Mix.env()
  @provider_gate Arbor.Security.ProviderGate
  @supervisor Arbor.Security.Supervisor

  @impl true
  def start(_type, _args) do
    # Application owns the claim table for the VM lifetime. Creating it in a
    # freeze caller lets that process's exit drop the table and reopen insert_new.
    # A pre-existing named table owned by anyone else is squatting: fail closed
    # before freeze or supervision so startup cannot continue with a mutable
    # foreign claim table.
    with :ok <- Arbor.Security.Config.ensure_enforcement_toggle_claim_table(),
         :ok <- Arbor.Security.Config.ensure_authority_root_claim_table() do
      start_supervised_children()
    end
  end

  defp start_supervised_children do
    Arbor.Security.Config.maybe_freeze_enforcement_toggles(@compile_env)

    signing_authority_owner_token = make_ref()

    with {:ok, snapshot} <- Arbor.Security.Config.startup_store_snapshot(:application),
         {:ok, profile} <- admit_profile(snapshot.start_profile) do
      children = children_from_snapshot(snapshot, signing_authority_owner_token)
      start_security_supervisor(profile, children)
    end
  end

  defp admit_profile(profile) when profile in [:full, :activation_only], do: {:ok, profile}
  defp admit_profile(other), do: {:error, {:invalid_start_profile, other}}

  defp start_security_supervisor(_profile, []) do
    Supervisor.start_link([], strategy: :rest_for_one, name: @supervisor)
  end

  defp start_security_supervisor(:full, children) do
    start_named([ProviderGate.child_spec([]) | children])
  end

  defp start_security_supervisor(_profile, children) do
    Supervisor.start_link(children, strategy: :rest_for_one, name: @supervisor)
  end

  defp start_named(children) do
    case Supervisor.start_link(children, strategy: :rest_for_one, name: @supervisor) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, normalize_gate_start_error(reason)}
    end
  end

  defp normalize_gate_start_error(reason) do
    case gate_child_reason(reason) do
      {:already_started, pid} when is_pid(pid) ->
        {:provider_gate_name_collision, pid}

      {:provider_gate_name_collision, pid} = typed when is_pid(pid) ->
        typed

      {:provider_start_failed, root, _inner} = typed when is_atom(root) ->
        typed

      _other ->
        reason
    end
  end

  defp gate_child_reason({:shutdown, inner}), do: gate_child_reason(inner)

  defp gate_child_reason({:failed_to_start_child, id, inner}) when id == @provider_gate,
    do: inner

  # OTP 28 Supervisor.start_link wraps as {reason, #child{}}.
  # Id is elem 2 and MFA is elem 3 on OTP 24 (size 8) and OTP 25+ (size 9).
  defp gate_child_reason({inner, child})
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    if provider_gate_child_record?(child), do: inner, else: :not_gate
  end

  defp gate_child_reason({inner, {mod, fun, args}})
       when mod == @provider_gate and is_atom(fun) and is_list(args),
       do: inner

  defp gate_child_reason(_), do: :not_gate

  defp provider_gate_child_record?(child)
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    id = elem(child, 2)
    mfargs = elem(child, 3)
    id == @provider_gate or match?({@provider_gate, :start_link, _}, mfargs)
  end

  defp provider_gate_child_record?(_), do: false

  defp children_from_snapshot(%{start_children: false}, _signing_authority_owner_token), do: []
  defp children_from_snapshot(%{start_children: nil}, _signing_authority_owner_token), do: []

  defp children_from_snapshot(snapshot, signing_authority_owner_token) do
    children_for_profile(snapshot, signing_authority_owner_token)
  end

  defp children_for_profile(
         %{start_profile: :activation_only} = snapshot,
         signing_authority_owner_token
       ) do
    core_security_children(snapshot, signing_authority_owner_token)
  end

  defp children_for_profile(snapshot, signing_authority_owner_token) do
    security_store_children(snapshot) ++
      core_security_children(snapshot, signing_authority_owner_token)
  end

  defp security_store_children(snapshot) do
    [
      authority_store_child(
        snapshot,
        :arbor_security_capabilities,
        "capabilities",
        hydration_limit: snapshot.capabilities_hydration_limit
      ),
      authority_store_child(snapshot, :arbor_security_identities, "identities"),
      authority_store_child(snapshot, :arbor_security_signing_keys, "signing_keys"),
      authority_store_child(snapshot, :arbor_security_issuers, "issuers")
    ]
  end

  defp authority_store_child(snapshot, name, namespace, extra \\ []) do
    store_opts =
      Arbor.Security.Config.authority_store_start_opts(name, namespace, snapshot, extra)

    Supervisor.child_spec({Arbor.Security.AuthorityStore, store_opts}, id: name)
  end

  defp core_security_children(snapshot, signing_authority_owner_token) do
    [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.IssuerRegistry, []},
      {Arbor.Security.Identity.NonceCache, []},
      # Classifies connected nodes for the signed-request replay gate. Before
      # NonceCache's consumers so the gate reads a live table; absent, every
      # peer counts as a replay peer (fail closed).
      {Arbor.Security.Identity.ReplayPeers, []},
      {Arbor.Security.SystemAuthority, []},
      # Persistent metadata outlives broker-only restarts; keys remain in SigningKeyStore.
      {Arbor.Security.SigningAuthorityStateOwner, broker_token: signing_authority_owner_token},
      # After key/identity stores + registry so open can fail-closed on status/key.
      {Arbor.Security.SigningAuthorityBroker, state_owner_token: signing_authority_owner_token},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []},
      {Arbor.Security.UriRegistry, []},
      {Arbor.Security.AuditJournalOwner,
       Arbor.Security.Config.audit_journal_start_opts(snapshot)},
      # Ephemeral one-use delivery receipts (same-node). Last so restart
      # loses outstanding receipts fail-closed without cascading earlier children.
      {Arbor.Security.DeliveryReceiptBroker, []}
    ]
  end
end
