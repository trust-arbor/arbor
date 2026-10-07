defmodule Arbor.Security.RegisteredNameTakeoverSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-004,SSEC-016"

  @moduletag security: :regression

  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Security
  alias Arbor.Security.Constraint.RateLimiter
  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.Identity.ReplayPeers
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Reflex
  alias Arbor.Security.SupervisedOwner
  alias Arbor.Security.TestBootstrap
  alias Arbor.Security.UriRegistry

  setup do
    on_exit(&TestBootstrap.restore_supervised_tree!/0)
    :ok
  end

  @tag :fast
  @tag spec: "SSEC-004,SSEC-016"
  test "security regression: a RateLimiter name squatter cannot bypass a rate constraint" do
    {:ok, identity} = Identity.generate(name: "rate-limiter-takeover")
    :ok = Registry.register_fixture(identity)
    resource = "arbor://shell/exec/rate-takeover-#{System.unique_integer([:positive])}"

    {:ok, capability} =
      Security.grant_fixture(
        principal: identity.agent_id,
        resource: resource,
        constraints: %{rate_limit: 1}
      )

    assert {:ok, :authorized} = Security.authorize(identity.agent_id, resource)

    try do
      with_name_takeover(RateLimiter, :ok, fn ->
        assert {:error, _reason} = Security.authorize(identity.agent_id, resource)
      end)
    after
      Security.revoke_fixture(capability.id)
      Security.deregister_identity_fixture(identity.agent_id)
    end
  end

  @tag :fast
  test "security regression: a NonceCache name squatter cannot admit a replay" do
    {:ok, identity} = Identity.generate(name: "nonce-cache-takeover")
    :ok = Registry.register_fixture(identity)
    agent_id = identity.agent_id

    {:ok, request} =
      SignedRequest.sign("nonce-cache-takeover", identity.agent_id, identity.private_key)

    assert {:ok, ^agent_id} = Security.verify_request(request)

    try do
      with_name_takeover(NonceCache, :ok, fn ->
        assert {:error, _reason} = Security.verify_request(request)
      end)
    after
      Security.deregister_identity_fixture(identity.agent_id)
    end
  end

  @tag :fast
  test "security regression: a forged reflex ETS table cannot remove built-in blockers" do
    with_name_takeover(Arbor.Security.Reflex.Registry, :ok, fn ->
      assert {:blocked, reflex, _message} = Security.check_reflex(%{command: "rm -rf /"})
      assert reflex.id == "rm_rf_root"
      assert {:ok, ^reflex} = Reflex.get(:rm_rf_root)
    end)
  end

  @tag :fast
  test "security regression: a UriRegistry name squatter cannot inject a runtime prefix" do
    ensure_application_child(UriRegistry)

    principal = "agent_uri_registry_takeover_#{System.unique_integer([:positive])}"
    prefix = "arbor://takeover/runtime_#{System.unique_integer([:positive])}"
    resource = prefix <> "/execute"
    original_enforcement = Application.get_env(:arbor_security, :uri_registry_enforcement)

    {:ok, capability} = Security.grant_fixture(principal: principal, resource: resource)
    Application.put_env(:arbor_security, :uri_registry_enforcement, true)

    try do
      with_name_takeover(UriRegistry, [prefix], fn ->
        assert {:error, {:uri_rejected, :unregistered_uri}} =
                 Security.authorize(principal, resource, :execute, verify_identity: false)
      end)
    after
      Security.revoke_fixture(capability.id)
      restore_env(:uri_registry_enforcement, original_enforcement)
    end
  end

  @tag :external
  @tag :integration
  @tag :slow
  test "security regression: a ReplayPeers name and ETS squatter cannot open the signed-request gate" do
    started_distributed = ensure_distributed_node()
    peer_name = random_name("replay_takeover")
    {:ok, peer, peer_node} = start_peer(peer_name)
    {:ok, identity} = Identity.generate(name: "replay-peers-takeover")
    :ok = Registry.register_fixture(Identity.public_only(identity))

    try do
      await(fn -> ReplayPeers.classification(peer_node) == :foreign end)

      {:ok, signed} =
        SignedRequest.sign("replay-peers-takeover", identity.agent_id, identity.private_key)

      connection_id = connected_connection_id(peer_node)

      install_replay_table = fn ->
        :ets.new(:arbor_security_replay_peers, [:named_table, :public, :set])

        :ets.insert(
          :arbor_security_replay_peers,
          {peer_node, :foreign, connection_id, System.monotonic_time(:millisecond) + 60_000}
        )
      end

      with_name_takeover(
        ReplayPeers,
        :foreign,
        fn ->
          assert {:error, :cluster_replay_protection_unavailable} =
                   Security.verify_request(signed)
        end,
        install_replay_table
      )
    after
      Security.deregister_identity_fixture(identity.agent_id)
      safely_stop_peer(peer)
      if started_distributed, do: Node.stop()
    end
  end

  defp with_name_takeover(child_id, forged_reply, assertion, squatter_setup \\ fn -> :ok end) do
    {:ok, root} = SupervisedOwner.application_root(:arbor_security)
    real = SupervisedOwner.registered_child(child_id, :arbor_security, [child_id])
    assert is_pid(real)
    assert :ok = Supervisor.terminate_child(root, child_id)
    refute Process.alive?(real)
    parent = self()

    squatter =
      spawn(fn ->
        true = Process.register(self(), child_id)

        if child_id == Arbor.Security.Reflex.Registry do
          :ets.new(:arbor_reflex_registry, [:named_table, :public, :set])
        end

        squatter_setup.()

        send(parent, {:name_squatter_ready, self()})
        squatter_loop(parent, forged_reply)
      end)

    assert_receive {:name_squatter_ready, ^squatter}

    try do
      assertion.()
      refute_receive {:name_squatter_called, _message}, 100
    after
      monitor = Process.monitor(squatter)
      if Process.whereis(child_id) == squatter, do: Process.unregister(child_id)
      if Process.alive?(squatter), do: Process.exit(squatter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^squatter, _reason}, 1_000
      restart_child(root, child_id)
    end
  end

  defp squatter_loop(parent, forged_reply) do
    receive do
      {:"$gen_call", {from, tag}, message} ->
        send(parent, {:name_squatter_called, message})
        send(from, {tag, forged_reply})
        squatter_loop(parent, forged_reply)

      message ->
        send(parent, {:name_squatter_called, message})
        squatter_loop(parent, forged_reply)
    end
  end

  defp restart_child(root, child_id) do
    case Supervisor.restart_child(root, child_id) do
      {:ok, pid} when is_pid(pid) -> await_registered(child_id, pid, 200)
      {:ok, pid, _info} when is_pid(pid) -> await_registered(child_id, pid, 200)
      {:error, :running} -> :ok
      {:error, reason} -> flunk("failed to restart #{inspect(child_id)}: #{inspect(reason)}")
    end
  end

  defp ensure_application_child(child_id) do
    {:ok, root} = SupervisedOwner.application_root(:arbor_security)

    case SupervisedOwner.registered_child(child_id, :arbor_security, [child_id]) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.start_child(root, {child_id, []}) do
          {:ok, pid} when is_pid(pid) -> await_registered(child_id, pid, 200)
          {:ok, pid, _info} when is_pid(pid) -> await_registered(child_id, pid, 200)
          {:error, :already_present} -> restart_child(root, child_id)
          {:error, {:already_started, pid}} -> await_registered(child_id, pid, 200)
          {:error, reason} -> flunk("failed to start #{inspect(child_id)}: #{inspect(reason)}")
        end
    end
  end

  defp await_registered(_name, _pid, 0), do: flunk("restarted child did not register")

  defp await_registered(name, pid, attempts) do
    if Process.whereis(name) == pid do
      :ok
    else
      Process.sleep(10)
      await_registered(name, pid, attempts - 1)
    end
  end

  defp ensure_distributed_node do
    if Node.alive?() do
      false
    else
      epmd = System.find_executable("epmd") || flunk("epmd executable is unavailable")
      {output, status} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
      assert status == 0, "epmd failed to start: #{output}"

      suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      name = String.to_atom("registered_name_takeover_#{suffix}@localhost")

      {:ok, _pid} = :net_kernel.start([name, :shortnames])
      true
    end
  end

  defp start_peer(name) do
    with {:ok, peer, peer_node} <-
           :peer.start_link(%{
             name: name,
             host: ~c"localhost",
             connection: :standard_io
           }) do
      case Node.connect(peer_node) do
        true -> {:ok, peer, peer_node}
        other -> {:error, {:distribution_connection_failed, peer_node, other}}
      end
    end
  end

  defp safely_stop_peer(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  defp random_name(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    String.to_atom("#{prefix}_#{suffix}")
  end

  defp connected_connection_id(peer_node) do
    :connected
    |> :erlang.nodes(%{connection_id: true})
    |> Map.new(fn {node, %{connection_id: connection_id}} -> {node, connection_id} end)
    |> Map.fetch!(peer_node)
  end

  defp await(fun, remaining_ms \\ 5_000)

  defp await(fun, remaining_ms) when remaining_ms <= 0 do
    assert fun.(), "condition did not become true before timeout"
  end

  defp await(fun, remaining_ms) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      await(fun, remaining_ms - 25)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
