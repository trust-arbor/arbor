defmodule Arbor.Actions.FacadeOpAuthorizationSecurityRegressionTest do
  @moduledoc """
  Security regression: `Arbor.Actions.authorize_facade_op/2` returned `:ok`
  when the context had no `:agent_id` ("system-level calls") and when Trust or
  Security authorization was unavailable. A missing principal or a missing
  authority must never mean system permission.
  """
  use ExUnit.Case, async: false

  alias Arbor.Actions

  @moduletag :fast
  @moduletag :security_regression

  @resource "arbor://action/test/facade-op-authorization-probe"

  defmodule UnavailableSecurity do
    @moduledoc false
    def capability_authorization_available?, do: false
  end

  defmodule RaisingSecurity do
    @moduledoc false
    def capability_authorization_available?, do: raise("security runtime crashed")
  end

  defmodule ExitingSecurity do
    @moduledoc false
    def capability_authorization_available?, do: exit(:noproc)
  end

  setup do
    previous = Application.fetch_env(:arbor_actions, :security_module)

    on_exit(fn ->
      case previous do
        {:ok, module} -> Application.put_env(:arbor_actions, :security_module, module)
        :error -> Application.delete_env(:arbor_actions, :security_module)
      end
    end)

    agent_id = "agent_facade_op_#{System.unique_integer([:positive])}"
    on_exit(fn -> Arbor.Security.revoke_all_fixture(agent_id) end)

    %{agent_id: agent_id}
  end

  describe "security regression: authorize_facade_op without a principal" do
    test "a context with no agent_id is refused, not passed through as system" do
      assert {:error, :invalid_authorization_principal} =
               Actions.authorize_facade_op(%{}, @resource)
    end

    test "nil, empty, blank and non-binary agent_ids are refused" do
      for agent_id <- [nil, "", "   ", :agent_atom, 42, %{id: "agent_x"}] do
        assert {:error, :invalid_authorization_principal} =
                 Actions.authorize_facade_op(%{agent_id: agent_id}, @resource),
               "agent_id #{inspect(agent_id)} was not refused"
      end
    end

    test "a non-map context is refused" do
      for context <- [nil, [agent_id: "agent_keyword"], "agent_string"] do
        assert {:error, :invalid_authorization_principal} =
                 Actions.authorize_facade_op(context, @resource),
               "context #{inspect(context)} was not refused"
      end
    end
  end

  describe "security regression: authorize_facade_op without authority" do
    test "an unavailable capability store is refused, not passed through", %{agent_id: agent_id} do
      # The agent holds a real grant, so the only thing standing between this
      # call and :ok is the availability check.
      grant!(agent_id)
      Application.put_env(:arbor_actions, :security_module, UnavailableSecurity)

      assert {:error, :authorization_unavailable} =
               Actions.authorize_facade_op(%{agent_id: agent_id}, @resource)
    end

    test "a missing, raising or exiting Security facade is refused", %{agent_id: agent_id} do
      grant!(agent_id)

      for security <- [RaisingSecurity, ExitingSecurity, Arbor.Actions.DefinitelyMissingSecurity] do
        Application.put_env(:arbor_actions, :security_module, security)

        assert {:error, :authorization_unavailable} =
                 Actions.authorize_facade_op(%{agent_id: agent_id}, @resource),
               "#{inspect(security)} was not treated as unavailable"
      end
    end
  end

  describe "authorize_facade_op with a principal and live authority" do
    test "an ungranted principal is refused and a granted one is authorized",
         %{agent_id: agent_id} do
      assert {:error, {:unauthorized, _reason}} =
               Actions.authorize_facade_op(%{agent_id: agent_id}, @resource)

      grant!(agent_id)
      assert :ok = Actions.authorize_facade_op(%{agent_id: agent_id}, @resource)
    end
  end

  defp grant!(agent_id) do
    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: @resource)
  end
end
