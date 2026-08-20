defmodule Arbor.Security.LocalHumanIdentitySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Identity.Registry

  setup do
    previous = Application.get_env(:arbor_security, :allow_local_human_identity)
    on_exit(fn -> Application.put_env(:arbor_security, :allow_local_human_identity, previous) end)
    :ok
  end

  defp local_identity(sub \\ "someone@somehost") do
    {:ok, base} = Identity.generate(name: "local operator")

    agent_id =
      "human_" <>
        String.slice(
          Base.encode16(:crypto.hash(:sha256, "arbor://local:#{sub}"), case: :lower),
          0,
          40
        )

    %{
      Identity.public_only(base)
      | agent_id: agent_id,
        metadata: %{
          "oidc_issuer" => "arbor://local",
          "oidc_sub" => sub,
          "identity_type" => "human"
        }
    }
  end

  test "security regression: local human registration is refused when the flag is off" do
    Application.put_env(:arbor_security, :allow_local_human_identity, false)

    assert {:error, :local_human_identity_disabled} =
             Registry.register_local_human(local_identity())
  end

  test "security regression: a non-local issuer cannot use the local path" do
    Application.put_env(:arbor_security, :allow_local_human_identity, true)

    forged = %{
      local_identity()
      | metadata: %{"oidc_issuer" => "https://accounts.google.com", "oidc_sub" => "12345"}
    }

    assert {:error, {:not_a_local_identity, _}} = Registry.register_local_human(forged)
  end

  test "security regression: a hand-chosen agent_id is rejected by the derivation check" do
    Application.put_env(:arbor_security, :allow_local_human_identity, true)

    tampered = %{local_identity() | agent_id: "human_" <> String.duplicate("a", 40)}

    assert {:error, {:oidc_identity_mismatch, _, :expected, _}} =
             Registry.register_local_human(tampered)
  end

  test "security regression: a registered local identity stops resolving once the flag is off" do
    Application.put_env(:arbor_security, :allow_local_human_identity, true)
    identity = local_identity("resolve-probe@host")

    case Registry.register_local_human(identity) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      other -> flunk("unexpected registration result: #{inspect(other)}")
    end

    assert {:ok, :active} = Registry.identity_status(identity.agent_id)

    # The detective control: a copied authority store must not authenticate a
    # local-issuer principal in an environment that did not mint it.
    Application.put_env(:arbor_security, :allow_local_human_identity, false)
    assert {:error, :not_found} = Registry.identity_status(identity.agent_id)
  end
end
