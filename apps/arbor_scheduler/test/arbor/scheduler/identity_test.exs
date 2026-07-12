defmodule Arbor.Scheduler.IdentityTest do
  @moduledoc """
  Focused checks for the scheduler's reload-stable authority lifecycle.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Scheduler.Identity
  alias Arbor.Security

  describe "authority without a running GenServer" do
    test "security regression: returns nil rather than a permissive fallback" do
      refute Process.whereis(Identity), "Identity must not be running in :fast tests"
      assert is_nil(Identity.signing_authority())
    end
  end

  describe "agent_id/0 without a running GenServer" do
    test "security regression: returns nil rather than a hardcoded id" do
      # Mirrors the authority contract: no live identity means no
      # caller can spoof one. A hardcoded fallback string would let
      # a misconfigured node masquerade as a valid scheduler.
      refute Process.whereis(Identity), "Identity must not be running in :fast tests"
      assert is_nil(Identity.agent_id())
    end
  end

  test "security regression: stable authority signs after Identity module reload" do
    {:ok, pid} = Identity.start_link()
    agent_id = Identity.agent_id()
    authority = Identity.signing_authority()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      Security.delete_signing_key(agent_id)
      Security.delete_signing_key("system_scheduler")
      Security.deregister_identity(agent_id)
    end)

    assert is_binary(agent_id)
    assert authority.principal_id == agent_id
    assert {:ok, _} = Security.sign_with_authority(authority, "before-reload")
    assert {:ok, private_key} = Security.load_signing_key(agent_id)

    state = :sys.get_state(pid)
    refute Enum.any?(Map.values(state), &is_function/1)
    refute :binary.match(:erlang.term_to_binary(state), private_key) != :nomatch

    :code.purge(Identity)
    :code.delete(Identity)
    assert Code.ensure_loaded?(Identity)

    assert {:ok, _} = Security.sign_with_authority(Identity.signing_authority(), "after-reload")
    assert {:ok, _} = Security.load_signing_key("system_scheduler")
  end

  test "security regression: legacy registered identity keeps the same principal across restart" do
    {:ok, legacy} = Arbor.Contracts.Security.Identity.generate()
    :ok = Security.store_signing_key("system_scheduler", legacy.private_key)
    :ok = Security.register_identity(legacy)

    on_exit(fn ->
      Security.delete_signing_key(legacy.agent_id)
      Security.delete_signing_key("system_scheduler")
      Security.deregister_identity(legacy.agent_id)
    end)

    {:ok, first_pid} = Identity.start_link()
    assert Identity.agent_id() == legacy.agent_id
    :ok = GenServer.stop(first_pid, :normal)

    {:ok, second_pid} = Identity.start_link()
    assert Identity.agent_id() == legacy.agent_id
    assert Identity.signing_authority().principal_id == legacy.agent_id
    :ok = GenServer.stop(second_pid, :normal)
  end
end
