defmodule Arbor.Security.Identity.ReplayPeersTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Identity.ReplayPeers
  alias Arbor.Security.TestBootstrap

  @moduletag :integration
  @moduletag :slow

  setup do
    started_distributed = ensure_distributed_node()
    on_exit(fn -> if started_distributed, do: Node.stop() end)
    :ok
  end

  test "security regression: stale probe generation cannot release new-generation waiters" do
    {peer, peer_node} = start_foreign_peer("replay_generation")
    on_exit(fn -> safely_stop_peer(peer) end)

    test_process = self()

    probe_fun = fn node, generation ->
      send(test_process, {:probe_started, self(), node, generation})

      receive do
        {:complete_probe, ^generation, classification} -> classification
      after
        5_000 -> :replay_peer
      end
    end

    tracker = restart_replay_peers(probe_fun: probe_fun)
    on_exit(fn -> TestBootstrap.restore_supervised_tree!() end)

    assert_receive {:probe_started, first_worker, ^peer_node, first_generation}, 1_000

    # Turn over the connection generation while the first probe is still
    # outstanding. The physical peer stays connected so the new generation can
    # acquire a waiter through the public gate.
    send(tracker, {:nodedown, peer_node})
    _state_after_down = :sys.get_state(tracker)
    send(tracker, {:nodeup, peer_node})

    assert_receive {:probe_started, second_worker, ^peer_node, second_generation}, 1_000
    refute first_generation == second_generation

    gate = Task.async(&ReplayPeers.peers_present?/0)

    await(fn ->
      state = :sys.get_state(tracker)
      Map.has_key?(state.waiters, {peer_node, second_generation})
    end)

    # This is the delayed result from the connection that already went down.
    # It must not cache :foreign, reply to the second generation's waiter, or
    # delete the second generation's inflight marker.
    send(tracker, {:probe_result, peer_node, first_generation, :foreign})
    state = :sys.get_state(tracker)

    assert state.inflight[peer_node] == second_generation
    assert Map.has_key?(state.waiters, {peer_node, second_generation})
    assert ReplayPeers.classification(peer_node) == :replay_peer
    assert Task.yield(gate, 50) == nil

    send(second_worker, {:complete_probe, second_generation, :replay_peer})
    assert Task.await(gate, 1_000)

    # Let the superseded worker exit; its real late result must also be ignored.
    send(first_worker, {:complete_probe, first_generation, :foreign})
    _final_state = :sys.get_state(tracker)
    assert ReplayPeers.classification(peer_node) == :replay_peer
  end

  test "security regression: expired foreign classification detects app start without reconnect" do
    restart_replay_peers(foreign_ttl_ms: 100)
    on_exit(fn -> TestBootstrap.restore_supervised_tree!() end)

    {peer, peer_node} = start_foreign_peer("replay_revalidation")
    on_exit(fn -> safely_stop_peer(peer) end)

    await(fn -> ReplayPeers.classification(peer_node) == :foreign end)

    # Bare :peer nodes do not inherit Mix's code path. Add the already-built
    # test paths so this connected peer can start the real application without
    # reconnecting.
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()], 5_000)

    install_peer_boot_profile!(peer_node)

    :ok =
      :erpc.call(
        peer_node,
        :application,
        :set_env,
        [:arbor_security, :start_children, false],
        5_000
      )

    assert {:ok, _started} =
             :erpc.call(peer_node, :application, :ensure_all_started, [:arbor_security], 10_000)

    assert :arbor_security in remote_applications(peer_node)

    Process.sleep(150)

    # The stale verdict becomes fail-closed immediately, and the resolved gate
    # then awaits the fresh asynchronous probe.
    assert ReplayPeers.classification(peer_node) == :replay_peer
    assert ReplayPeers.peers_present?()
    assert ReplayPeers.classification(peer_node) == :replay_peer
  end

  test "recovery: a transient probe failure heals after the replay TTL" do
    test_process = self()

    probe_fun = fn node, generation ->
      send(test_process, {:probe_started, self(), node, generation})

      receive do
        {:complete_probe, ^generation, classification} -> classification
      after
        5_000 -> :replay_peer
      end
    end

    {peer, peer_node} = start_foreign_peer("replay_healing")
    on_exit(fn -> safely_stop_peer(peer) end)

    tracker =
      restart_replay_peers(
        probe_fun: probe_fun,
        replay_peer_ttl_ms: 200,
        foreign_ttl_ms: 60_000
      )

    on_exit(fn -> TestBootstrap.restore_supervised_tree!() end)

    # The peer was already connected, so init probes it. Fail that probe the
    # way a Doze/timeout does: the worker reports :replay_peer.
    assert_receive {:probe_started, first_worker, ^peer_node, first_generation}, 1_000
    send(first_worker, {:complete_probe, first_generation, :replay_peer})

    await(fn -> not Map.has_key?(:sys.get_state(tracker).inflight, peer_node) end)
    assert ReplayPeers.classification(peer_node) == :replay_peer
    assert ReplayPeers.peers_present?()

    # A fresh (within-TTL) fail-closed verdict is served from cache: the
    # reads above must NOT have scheduled another probe of the peer.
    refute_receive {:probe_started, _worker, ^peer_node, _generation}, 50

    # Let the fail-closed verdict expire. Expiry must not open the gate on
    # its own — the next read still refuses, but schedules a fresh probe.
    Process.sleep(250)
    assert ReplayPeers.classification(peer_node) == :replay_peer

    assert_receive {:probe_started, second_worker, ^peer_node, second_generation}, 1_000

    # While the healing probe is in flight, every read keeps failing closed
    # and none of them block on the possibly-still-unresponsive peer. The
    # expired row must still be present — deleting it would send readers
    # into the blocking await instead of the instant fail-closed answer.
    assert [{^peer_node, :replay_peer, _connection_id, _expires_at}] =
             :ets.lookup(:arbor_security_replay_peers, peer_node)

    assert ReplayPeers.classification(peer_node) == :replay_peer
    assert ReplayPeers.peers_present?()

    # The peer recovered: the probe now gets a positive answer, and the node
    # is downgraded without its dist connection ever having dropped.
    send(second_worker, {:complete_probe, second_generation, :foreign})
    await(fn -> ReplayPeers.classification(peer_node) == :foreign end)
    refute ReplayPeers.peers_present?()
  end

  test "recovery: expiry keeps refusing while the peer stays unresponsive" do
    test_process = self()

    probe_fun = fn node, generation ->
      send(test_process, {:probe_started, self(), node, generation})

      receive do
        {:complete_probe, ^generation, classification} -> classification
      after
        5_000 -> :replay_peer
      end
    end

    {peer, peer_node} = start_foreign_peer("replay_still_down")
    on_exit(fn -> safely_stop_peer(peer) end)

    tracker =
      restart_replay_peers(
        probe_fun: probe_fun,
        replay_peer_ttl_ms: 100,
        foreign_ttl_ms: 60_000
      )

    on_exit(fn -> TestBootstrap.restore_supervised_tree!() end)

    assert_receive {:probe_started, first_worker, ^peer_node, first_generation}, 1_000
    send(first_worker, {:complete_probe, first_generation, :replay_peer})
    await(fn -> not Map.has_key?(:sys.get_state(tracker).inflight, peer_node) end)

    # Two full expiry cycles against a peer that keeps failing its probes:
    # the gate must refuse at every point in the cycle.
    for _cycle <- 1..2 do
      Process.sleep(150)
      assert ReplayPeers.classification(peer_node) == :replay_peer
      assert ReplayPeers.peers_present?()

      assert_receive {:probe_started, worker, ^peer_node, generation}, 1_000
      assert ReplayPeers.peers_present?()

      send(worker, {:complete_probe, generation, :replay_peer})
      await(fn -> not Map.has_key?(:sys.get_state(tracker).inflight, peer_node) end)
      assert ReplayPeers.classification(peer_node) == :replay_peer
    end
  end

  test "probe timeout is configurable and publishes the derived await cap" do
    restart_replay_peers(probe_timeout_ms: 1_234)
    on_exit(fn -> TestBootstrap.restore_supervised_tree!() end)

    assert [{:__replay_peers_config__, 1_734}] =
             :ets.lookup(:arbor_security_replay_peers, :__replay_peers_config__)
  end

  defp restart_replay_peers(opts) do
    supervisor = Arbor.Security.Supervisor

    case Supervisor.terminate_child(supervisor, ReplayPeers) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(supervisor, ReplayPeers) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    child = Supervisor.child_spec({ReplayPeers, opts}, id: ReplayPeers)
    {:ok, pid} = Supervisor.start_child(supervisor, child)
    pid
  end

  defp start_foreign_peer(prefix) do
    peer_name = String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
    {:ok, peer, peer_node} = start_peer(peer_name)
    {peer, peer_node}
  end

  defp install_peer_boot_profile!(peer_node) do
    # Bare peers do not inherit Mix test startup or config. Start the verifier
    # prerequisites, load its compile-time test clock, then bind and compare the
    # same signed activation-only profile before Security marks the peer capable.
    runtime = Application.get_env(:arbor_kernel, :kernel_runtime, [])
    assert Keyword.keyword?(runtime)
    assert Keyword.has_key?(runtime, :boot_profile)

    peer_runtime = Keyword.put(runtime, :start_profile, :activation_only)

    assert {:ok, _} =
             :erpc.call(peer_node, :application, :ensure_all_started, [:elixir], 5_000)

    assert {:ok, _} =
             :erpc.call(peer_node, :application, :ensure_all_started, [:crypto], 5_000)

    assert {:module, Arbor.KernelRuntime.BootProfileBinding.Testing} =
             :erpc.call(
               peer_node,
               Code,
               :ensure_loaded,
               [Arbor.KernelRuntime.BootProfileBinding.Testing],
               5_000
             )

    :ok =
      :erpc.call(
        peer_node,
        Application,
        :put_env,
        [:arbor_kernel, :kernel_runtime, peer_runtime, [persistent: true]],
        5_000
      )

    assert {:ok, _} =
             :erpc.call(
               peer_node,
               Application,
               :ensure_all_started,
               [:arbor_kernel_runtime],
               10_000
             )

    assert {:ok, host_snapshot} = Arbor.KernelRuntime.boot_profile()

    assert {:ok, peer_snapshot} =
             :erpc.call(peer_node, Arbor.KernelRuntime, :boot_profile, [], 5_000)

    assert peer_snapshot["schema"] == "arbor.kernel_runtime.boot_profile_binding.v1"
    assert peer_snapshot["manifest_sha256"] == host_snapshot["manifest_sha256"]
    assert peer_snapshot["profile_id"] == host_snapshot["profile_id"]
    :ok
  end

  defp remote_applications(node) do
    node
    |> :erpc.call(:application, :which_applications, [], 5_000)
    |> Enum.map(&elem(&1, 0))
  end

  defp ensure_distributed_node do
    if Node.alive?() do
      false
    else
      start_epmd!()

      name =
        String.to_atom(
          "replay_peers_test_#{System.unique_integer([:positive, :monotonic])}@localhost"
        )

      {:ok, _} = :net_kernel.start([name, :shortnames])
      true
    end
  end

  defp start_epmd! do
    epmd = System.find_executable("epmd") || flunk("epmd executable is unavailable")

    case System.cmd(epmd, ["-daemon"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("epmd failed to start (#{code}): #{output}")
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
        true ->
          {:ok, peer, peer_node}

        other ->
          safely_stop_peer(peer)
          {:error, {:distribution_connection_failed, peer_node, other}}
      end
    end
  end

  defp safely_stop_peer(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
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
end
