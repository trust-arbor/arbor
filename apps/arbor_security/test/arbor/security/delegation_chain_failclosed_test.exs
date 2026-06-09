defmodule Arbor.Security.DelegationChainFailClosedTest do
  @moduledoc """
  **Security regression guard (M1 review fix, 2026-06-09).**

  `AuthDecision.check_delegation_chain/2` used to `rescue _ -> {:ok, auth}`,
  so any exception while cryptographically verifying a capability's
  delegation chain silently ACCEPTED the chain — converting the signature
  check into a no-op on the error path. (This is the last-line delegation
  gate; the load-bearing case is the preloaded-capability fallback when the
  CapabilityStore is unavailable, where the store's own delegation check
  doesn't run.)

  Setup: mint a REAL, validly-signed delegated capability (so the store
  accepts it on lookup), then point ONLY AuthDecision's delegation signer
  — via `Config.delegation_signer_module/0` — at a stub that raises. The
  store still verifies with the real Signer and returns the cap; AuthDecision
  then hits its rescue path.

  On HEAD~1 the assertion FAILS ({:ok, :authorized}); on HEAD it denies with
  `{:delegation_chain_invalid, _}`.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{AuthContext, Identity}
  alias Arbor.Security
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.Identity.Registry

  defmodule RaisingSigner do
    @moduledoc false
    def verify_delegation_chain(_cap, _key_lookup_fn),
      do: raise("simulated delegation-chain verification failure")
  end

  setup do
    ensure_security_started()

    prev = %{
      delegation_enabled:
        Application.get_env(:arbor_security, :delegation_chain_verification_enabled),
      signer: Application.get_env(:arbor_security, :delegation_signer_module),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement)
    }

    Application.put_env(:arbor_security, :delegation_chain_verification_enabled, true)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    on_exit(fn ->
      restore(:delegation_chain_verification_enabled, prev.delegation_enabled)
      restore(:delegation_signer_module, prev.signer)
      restore(:capability_signing_required, prev.signing)
      restore(:strict_identity_mode, prev.strict)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
    end)

    {:ok, parent} = Identity.generate(name: "delchain-parent")
    {:ok, agent} = Identity.generate(name: "delchain-agent")
    :ok = Registry.register(parent)
    :ok = Registry.register(agent)

    {:ok, parent: parent, agent: agent}
  end

  test "delegation-chain verification crash DENIES (does not authorize)",
       %{parent: parent, agent: agent} do
    uri = "arbor://historian/query"

    # Parent holds the resource, then delegates it to the agent. This mints
    # a real, validly-signed delegation chain stored against the agent — the
    # store will accept it on lookup (via the real Signer).
    {:ok, _parent_cap} =
      Security.grant(principal: parent.agent_id, resource: uri, delegation_depth: 3)

    {:ok, [delegated]} =
      Security.delegate_to_agent(parent.agent_id, agent.agent_id,
        delegator_private_key: parent.private_key,
        resources: [uri]
      )

    assert length(delegated.delegation_chain) == 1

    # Now make ONLY AuthDecision's delegation verifier raise. The store still
    # uses the real Signer and returns the cap; AuthDecision hits its rescue.
    Application.put_env(:arbor_security, :delegation_signer_module, RaisingSigner)

    auth =
      AuthContext.new(agent.agent_id, capabilities: [delegated])
      |> AuthContext.mark_verified()

    result = AuthDecision.evaluate(auth, uri, :query)

    refute match?({:ok, :authorized, _, _}, result),
           "delegation verification crash must NOT authorize (fail-open); got #{inspect(result)}"

    assert match?({:error, {:delegation_chain_invalid, _}, _}, result),
           "expected fail-closed delegation_chain_invalid; got #{inspect(result)}"
  end

  defp ensure_security_started do
    children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    if Process.whereis(Arbor.Security.Supervisor) do
      for child <- children do
        try do
          case Supervisor.start_child(Arbor.Security.Supervisor, child) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            {:error, :already_present} -> :ok
            _ -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)
end
