defmodule Arbor.Actions.SandboxSecurityRegressionTest do
  @moduledoc """
  Security regression: sandbox actions are an agent/extension surface.

  Parent behavior (must fail on checkout of the exact parent):
  `Create.run/2` and `Destroy.run/2` fall back to unauthenticated
  `Arbor.Sandbox.create/2` / `destroy/1` when `context[:agent_id]` is
  missing, so an action/extension caller can create or destroy a sandbox
  without a caller principal.

  Fixed behavior: missing `context[:agent_id]` fails closed with the
  existing Unauthorized vocabulary and never creates or destroys. The
  authorized path still uses `authorize_create` / `authorize_destroy`.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Sandbox

  setup do
    case Process.whereis(Arbor.Sandbox.Registry) do
      nil ->
        {:ok, _pid} = Arbor.Sandbox.Registry.start_link([])

      _pid ->
        :ok
    end

    unique = System.unique_integer([:positive])
    caller_id = "agent_p1b_sandbox_caller_#{unique}"
    target_id = "agent_p1b_sandbox_target_#{unique}"

    base_path =
      Path.join(System.tmp_dir!(), "arbor_actions_sandbox_sec_#{unique}")

    File.mkdir_p!(base_path)

    on_exit(fn ->
      cleanup_sandbox(target_id)
      cleanup_sandbox(caller_id)
      File.rm_rf(base_path)

      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(caller_id)
      end
    end)

    {:ok, caller_id: caller_id, target_id: target_id, base_path: base_path}
  end

  test "security regression: Create.run/2 without context[:agent_id] is denied and does not create",
       %{target_id: target_id} do
    assert {:error, "Unauthorized: :missing_agent_id"} =
             Sandbox.Create.run(%{agent_id: target_id}, %{})

    assert {:error, :not_found} = Arbor.Sandbox.get(target_id)
  end

  test "security regression: Destroy.run/2 without context[:agent_id] is denied and does not destroy",
       %{target_id: target_id, base_path: base_path} do
    {:ok, sandbox} = Arbor.Sandbox.create(target_id, base_path: base_path)

    assert {:error, "Unauthorized: :missing_agent_id"} =
             Sandbox.Destroy.run(%{sandbox_id: sandbox.id}, %{})

    assert {:ok, ^sandbox} = Arbor.Sandbox.get(sandbox.id)
  end

  test "security regression: Create.run/2 with a caller uses authorize_create and denies without a grant",
       %{caller_id: caller_id, target_id: target_id} do
    assert {:error, message} =
             Sandbox.Create.run(%{agent_id: target_id}, %{agent_id: caller_id})

    assert message =~ "Unauthorized"
    assert {:error, :not_found} = Arbor.Sandbox.get(target_id)
  end

  test "security regression: authorized Create.run/2 uses authorize_create and creates",
       %{caller_id: caller_id, target_id: target_id} do
    assert {:ok, _capability} =
             Arbor.Security.grant(principal: caller_id, resource: "arbor://sandbox/create")

    assert {:ok, result} =
             Sandbox.Create.run(%{agent_id: target_id}, %{agent_id: caller_id})

    assert result.status == "created"
    assert result.agent_id == target_id
    assert {:ok, sandbox} = Arbor.Sandbox.get(result.sandbox_id)
    assert sandbox.agent_id == target_id
  end

  test "security regression: authorized Destroy.run/2 uses authorize_destroy",
       %{caller_id: caller_id, target_id: target_id, base_path: base_path} do
    {:ok, sandbox} = Arbor.Sandbox.create(target_id, base_path: base_path)

    assert {:error, message} =
             Sandbox.Destroy.run(%{sandbox_id: sandbox.id}, %{agent_id: caller_id})

    assert message =~ "Unauthorized"
    assert {:ok, ^sandbox} = Arbor.Sandbox.get(sandbox.id)

    assert {:ok, _capability} =
             Arbor.Security.grant(principal: caller_id, resource: "arbor://sandbox/destroy")

    assert {:ok, result} =
             Sandbox.Destroy.run(%{sandbox_id: sandbox.id}, %{agent_id: caller_id})

    assert result.status == "destroyed"
    assert {:error, :not_found} = Arbor.Sandbox.get(sandbox.id)
  end

  defp cleanup_sandbox(id) do
    if Process.whereis(Arbor.Sandbox.Registry) do
      case Arbor.Sandbox.get(id) do
        {:ok, sandbox} -> Arbor.Sandbox.destroy(sandbox.id)
        {:error, :not_found} -> :ok
      end
    end

    File.rm_rf(Path.expand("~/.arbor/sandbox/agents/#{id}"))
  end
end
