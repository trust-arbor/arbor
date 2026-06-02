defmodule Arbor.Security.RoleTest do
  @moduledoc """
  Tests for role-based capability assignment.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Role

  setup do
    {:ok, identity} = Identity.generate(name: "role-test-human")
    :ok = Registry.register(identity)
    {:ok, identity: identity, agent_id: identity.agent_id}
  end

  describe "Role.get/1" do
    test "returns admin role URIs" do
      assert {:ok, uris} = Role.get(:admin)
      assert "arbor://**" in uris
    end

    test "returns error for unknown role" do
      assert {:error, :unknown_role} = Role.get(:nonexistent)
    end
  end

  describe "Role.list/0" do
    test "includes admin" do
      assert :admin in Role.list()
    end
  end

  describe "Role.default_human_role/0" do
    test "security regression (M1): defaults to :viewer (least privilege)" do
      # M1: default used to be :admin — every OIDC user got root-equivalent
      # caps without opting in. Now defaults to :viewer; operators set the
      # default explicitly via config if they want a richer baseline.
      original = Application.get_env(:arbor_security, :default_human_role)
      Application.delete_env(:arbor_security, :default_human_role)

      try do
        assert Role.default_human_role() == :viewer,
               "Default human role must be :viewer (least privilege) — M1 regression"
      after
        if original do
          Application.put_env(:arbor_security, :default_human_role, original)
        end
      end
    end
  end

  describe "Security.assign_role/3" do
    test "grants admin capabilities", %{agent_id: agent_id} do
      {:ok, caps} = Security.assign_role(agent_id, :admin)
      assert length(caps) >= 1

      admin_cap = Enum.find(caps, &(&1.resource_uri == "arbor://**"))
      assert admin_cap != nil
      assert admin_cap.principal_id == agent_id
    end

    test "admin role authorizes any resource", %{agent_id: agent_id} do
      {:ok, _caps} = Security.assign_role(agent_id, :admin)

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/**", nil, verify_identity: false)

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://shell/execute/**", nil,
                 verify_identity: false
               )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://anything/at/all", nil,
                 verify_identity: false
               )
    end

    test "returns error for unknown role", %{agent_id: agent_id} do
      assert {:error, :unknown_role} = Security.assign_role(agent_id, :nonexistent)
    end

    test "idempotent — second assign doesn't fail", %{agent_id: agent_id} do
      {:ok, caps1} = Security.assign_role(agent_id, :admin)
      {:ok, _caps2} = Security.assign_role(agent_id, :admin)

      # Should still have the capabilities
      {:ok, all_caps} = Security.list_capabilities(agent_id)
      assert length(all_caps) >= length(caps1)
    end

    test "admin can delegate to agents", %{identity: identity} do
      {:ok, _caps} = Security.assign_role(identity.agent_id, :admin)

      {:ok, agent} = Identity.generate(name: "child-agent")
      :ok = Registry.register(agent)

      {:ok, delegated} =
        Security.delegate_to_agent(identity.agent_id, agent.agent_id,
          delegator_private_key: identity.private_key,
          resources: ["arbor://fs/read/**"]
        )

      assert length(delegated) == 1
      assert hd(delegated).principal_id == agent.agent_id
    end
  end

  describe "config-driven roles" do
    setup do
      prev = Application.get_env(:arbor_security, :roles)

      Application.put_env(:arbor_security, :roles, %{
        viewer: ["arbor://fs/read/**", "arbor://memory/read/**"]
      })

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbor_security, :roles, prev),
          else: Application.delete_env(:arbor_security, :roles)
      end)

      :ok
    end

    test "custom role is available" do
      assert {:ok, uris} = Role.get(:viewer)
      assert "arbor://fs/read/**" in uris
      assert "arbor://memory/read/**" in uris
    end

    test "builtin admin still available alongside custom roles" do
      assert {:ok, _} = Role.get(:admin)
      assert {:ok, _} = Role.get(:viewer)
    end

    test "custom role grants specific capabilities", %{agent_id: agent_id} do
      {:ok, caps} = Security.assign_role(agent_id, :viewer)
      assert length(caps) == 2
    end
  end

  describe ":dev_admin role (OQ-2)" do
    setup do
      original = Application.get_env(:arbor_security, :enable_dev_admin_role)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:arbor_security, :enable_dev_admin_role)
        else
          Application.put_env(:arbor_security, :enable_dev_admin_role, original)
        end
      end)

      :ok
    end

    test "is unavailable by default (production posture)" do
      Application.delete_env(:arbor_security, :enable_dev_admin_role)
      assert {:error, :unknown_role} = Role.get(:dev_admin)
      refute :dev_admin in Role.list()
    end

    test "is unavailable when the flag is explicitly false" do
      Application.put_env(:arbor_security, :enable_dev_admin_role, false)
      assert {:error, :unknown_role} = Role.get(:dev_admin)
    end

    test "becomes available with the bundled dev capabilities when the flag is true" do
      Application.put_env(:arbor_security, :enable_dev_admin_role, true)

      assert {:ok, uris} = Role.get(:dev_admin)
      assert "arbor://consensus/admin" in uris
      assert "arbor://trust/auto_promote/**" in uris
      assert "arbor://signals/subscribe/security" in uris

      assert :dev_admin in Role.list()
    end
  end
end
