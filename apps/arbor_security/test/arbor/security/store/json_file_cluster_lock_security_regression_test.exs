defmodule Arbor.Security.Store.JSONFileClusterLockSecurityRegressionTest do
  @moduledoc """
  Security regression for the connected-cluster JSONFile namespace lock.

  Two real BEAM nodes share one filesystem root and race the same
  compare-and-swap. A node-local lock admits both writers; the connected-node
  lock admits exactly one.
  """

  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-016"

  @moduletag :distributed
  @moduletag :integration
  @moduletag :slow
  @moduletag timeout: 120_000

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.TestSupport.JSONFileClusterTestHelper, as: Helper

  @helper_file Path.expand("../../../support/json_file_cluster_test_helper.ex", __DIR__)
  @record_auth_key :crypto.hash(:sha256, "json-file-cluster-lock-security-regression")
  # Keep the value below TaintEnvelope's per-string bound while making the
  # pre-fix read/encode/write race wide enough to reproduce reliably.
  @payload_bytes 60_000

  setup_all do
    case ensure_distribution() do
      :ok -> :ok
      {:error, reason} -> {:skip, "cannot start distribution: #{inspect(reason)}"}
    end
  end

  @tag spec: "SSEC-016"
  test "security regression: two connected nodes sharing one root admit one CAS winner" do
    root = unique_dir("jsonfile-cluster-cas")
    opts = [base_dir: root, name: "cluster_lock", record_auth_key: @record_auth_key]

    {:ok, peer_a, node_a} = start_peer("jsonfile_cas_a")
    {:ok, peer_b, node_b} = start_peer("jsonfile_cas_b")

    try do
      assert true == :erpc.call(node_a, Node, :connect, [node_b])
      assert_connected(node_a, node_b)

      for remote <- [node_a, node_b] do
        assert {:ok, _started} = :erpc.call(remote, Application, :ensure_all_started, [:elixir])
        assert {:ok, _started} = :erpc.call(remote, Application, :ensure_all_started, [:crypto])
        _loaded = :erpc.call(remote, Code, :require_file, [@helper_file])
        assert true == :erpc.call(remote, Code, :ensure_loaded?, [Helper])
        assert :ok = :erpc.call(remote, :global, :sync, [])
      end

      for round <- 1..12 do
        key = "shared-key-#{round}"
        ready_ref = make_ref()
        release_ref = make_ref()
        parent = self()

        calls = [
          Task.async(fn ->
            :erpc.call(
              node_a,
              Helper,
              :contend,
              [parent, ready_ref, release_ref, key, opts, "a", @payload_bytes],
              60_000
            )
          end),
          Task.async(fn ->
            :erpc.call(
              node_b,
              Helper,
              :contend,
              [parent, ready_ref, release_ref, key, opts, "b", @payload_bytes],
              60_000
            )
          end)
        ]

        contenders = await_contenders(ready_ref, 2, [])
        Enum.each(contenders, &send(&1, {:release, release_ref}))

        results = Enum.map(calls, &Task.await(&1, 65_000))

        assert Enum.count(results, &match?({:ok, %Record{}}, &1)) == 1,
               "connected nodes produced multiple CAS winners: #{inspect(results, limit: 5)}"

        assert Enum.count(results, &match?({:error, :conflict}, &1)) == 1

        assert {:ok, %Record{} = stored_a} = :erpc.call(node_a, Helper, :get, [key, opts])
        assert {:ok, %Record{} = stored_b} = :erpc.call(node_b, Helper, :get, [key, opts])
        assert stored_a == stored_b
      end
    after
      :peer.stop(peer_b)
      :peer.stop(peer_a)
      File.rm_rf!(root)
    end
  end

  defp ensure_distribution do
    if Node.alive?() do
      :ok
    else
      name = random_name("jsonfile_cas_origin")

      case :net_kernel.start([name, :shortnames]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_peer(prefix) do
    name = random_name(prefix)

    :peer.start_link(%{
      name: name,
      longnames: false,
      args: peer_code_path_args(),
      wait_boot: 30_000
    })
  end

  defp peer_code_path_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end

  defp assert_connected(node_a, node_b, attempts \\ 100)

  defp assert_connected(_node_a, _node_b, 0),
    do: flunk("peer nodes did not form a connected distribution cluster")

  defp assert_connected(node_a, node_b, attempts) do
    connected_from_a = :erpc.call(node_a, Node, :list, [:connected])
    connected_from_b = :erpc.call(node_b, Node, :list, [:connected])

    if node_b in connected_from_a and node_a in connected_from_b do
      :ok
    else
      Process.sleep(10)
      assert_connected(node_a, node_b, attempts - 1)
    end
  end

  defp await_contenders(_ready_ref, 0, contenders), do: contenders

  defp await_contenders(ready_ref, remaining, contenders) do
    receive do
      {^ready_ref, _node, pid} when is_pid(pid) ->
        await_contenders(ready_ref, remaining - 1, [pid | contenders])
    after
      30_000 -> flunk("timed out waiting for remote CAS contenders")
    end
  end

  defp unique_dir(label) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "#{label}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp random_name(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    String.to_atom("#{prefix}_#{suffix}")
  end
end
