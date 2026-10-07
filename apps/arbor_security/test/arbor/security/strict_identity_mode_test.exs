defmodule Arbor.Security.StrictIdentityModeTest do
  @moduledoc """
  **Security regression guard (M3 review fix, 2026-06-09).**

  When `strict_identity_mode` is ON, an UNREGISTERED principal must be denied
  at the identity layer — even on the facade path (`verify_identity: false`)
  and even when it holds a matching capability. When OFF, the identity check
  is permissive and the principal proceeds past it (fail-open).

  `config/dev.exs` now enables strict mode to match prod. This test guards
  the underlying behavior the config relies on: if `check_identity_status/2`
  is ever weakened so an unknown principal proceeds under strict mode, this
  fails. The contrast (strict on → denied, strict off → proceeds) proves the
  strict flag is the discriminator.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Identity.Registry

  setup do
    ensure_security_started()

    prev = %{
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement)
    }

    # Keep signing off and reflexes off so identity is the only variable.
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    on_exit(fn ->
      restore(:strict_identity_mode, prev.strict)
      restore(:capability_signing_required, prev.signing)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
    end)

    # An UNREGISTERED principal — well-formed agent_<hex> so `grant/1`
    # accepts it, but never put through Identity.Registry, so its
    # identity_status is :not_found. It holds a matching capability; the
    # facade path skips signed-request verification, so identity status is
    # the deciding gate.
    hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    principal = "agent_" <> hex
    uri = "arbor://historian/query"

    {:ok, _cap} = Security.grant_fixture(principal: principal, resource: uri)

    {:ok, principal: principal, uri: uri}
  end

  test "strict mode ON denies an unregistered principal at the identity layer",
       %{principal: principal, uri: uri} do
    Application.put_env(:arbor_security, :strict_identity_mode, true)

    assert {:error, _reason} =
             Security.authorize(principal, uri, :query, verify_identity: false)
  end

  test "strict mode OFF lets the same unregistered principal past the identity check",
       %{principal: principal, uri: uri} do
    Application.put_env(:arbor_security, :strict_identity_mode, false)

    # Identity check is permissive → the request proceeds past identity and
    # the held capability is honored (gated to :pending_approval by the
    # default trust ceiling, or authorized — either way NOT an identity
    # denial). This is the fail-open behavior strict mode closes.
    result = Security.authorize(principal, uri, :query, verify_identity: false)

    assert match?({:ok, :authorized}, result) or
             match?({:ok, :pending_approval, _}, result),
           "expected the unregistered principal to pass the identity gate when " <>
             "strict mode is off; got #{inspect(result)}"
  end

  test "security regression: preverified identity still checks current standing" do
    {:ok, identity} = Identity.generate(name: "preverified-standing")
    :ok = Registry.register_fixture(identity)

    uri = "arbor://historian/query/#{System.unique_integer([:positive])}"
    {:ok, _cap} = Security.grant_fixture(principal: identity.agent_id, resource: uri)
    :ok = Security.suspend_identity_fixture(identity.agent_id, reason: "security regression")

    assert {:error, {:unauthorized, :identity_suspended}} =
             Security.authorize(identity.agent_id, uri, :query,
               identity_verified: true,
               verify_identity: true
             )
  end

  test "security regression: development config does not allow arbitrary OIDC subjects" do
    dev_config =
      Path.expand("../../../../../config/dev.exs", __DIR__)
      |> File.read!()

    refute dev_config =~ "oidc_registration_mode: :allow"
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
