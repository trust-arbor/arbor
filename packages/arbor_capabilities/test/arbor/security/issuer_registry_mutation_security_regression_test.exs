defmodule Arbor.Security.IssuerRegistryMutationSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-001,SSEC-004"

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  @moduletag :fast

  @tag spec: "SSEC-001,SSEC-004"
  test "security regression: unauthenticated callers cannot create or mutate issuer authority" do
    {:ok, identity} = Identity.generate(name: "issuer-mutation-attacker")
    :ok = IdentityRegistry.register_fixture(identity)

    {:ok, envelope} =
      Capability.new(
        resource_uri: "arbor://fs/read/issuer-security-regression/**",
        principal_id: identity.agent_id
      )

    assert {:error, :issuer_mutation_unauthorized} =
             IssuerRegistry.register(identity.agent_id, [envelope], reason: "forged enrollment")

    assert {:error, :issuer_mutation_unauthorized} =
             IssuerRegistry.update_envelopes(identity.agent_id, [envelope],
               reason: "forged update"
             )

    assert {:error, :issuer_mutation_unauthorized} =
             IssuerRegistry.revoke(identity.agent_id, "forged revocation")

    assert {:error, :not_found} = IssuerRegistry.lookup(identity.agent_id)
  end
end
