defmodule Arbor.Security.AuditRetirementPeerRestartTest do
  @moduledoc """
  Whole-BEAM restart fast lane for terminal-identity retirement
  (Floor-and-Ledger v3, slice 3, test (m)).

  Peer A runs a durable operational journal owner under a realpath root with
  a registered audit consumer and drives 700 v3 lifecycles (one T2 retiring
  publication at 512 delivered). Peer A is stopped (the whole BEAM halts; no
  graceful close is required). Peer B opens the same root in a fresh BEAM and
  reconstructs the identical status, the admission floor and the bound
  ledger; late inputs answer per the crash table (B5).

  The real Historian sink lane is slice 4. New-API test: fails on the parent
  52a2cc3fa by absence (no retirement status, test arities or ledger).
  """
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag :integration
  @moduletag timeout: 600_000

  alias Arbor.Common.SafePath

  driver =
    defmodule PeerDriver do
      @moduledoc false
      # Shipped to the peers as object code; runs only lib modules there.
      alias Arbor.Security.AuditJournalOwner, as: Owner
      alias Arbor.Security.Contracts.AuditJournal

      @time "2026-09-28T12:00:00Z"

      def boot(consumer) do
        {:ok, _} = Application.ensure_all_started(:elixir)
        {:ok, _} = Application.ensure_all_started(:logger)
        {:ok, _} = Application.ensure_all_started(:telemetry)
        Application.put_env(:arbor_security, :authority_audit_consumer_name, consumer)
        Application.put_env(:arbor_security, :authority_audit_consumer_application, :test)
        :ok
      end

      # The owner outlives the erpc call: it is linked to a parked holder.
      def start_owner(opts) do
        caller = self()

        spawn(fn ->
          send(caller, {:started, Owner.start_link(opts)})
          Process.sleep(:infinity)
        end)

        receive do
          {:started, result} -> result
        after
          120_000 -> {:error, :start_timeout}
        end
      end

      # Prepare, observe, fetch and acknowledge `range` lifecycles as the
      # registered consumer. Returns every unexpected reply.
      def drive(name, consumer, range) do
        true = Process.register(self(), consumer)

        try do
          Enum.flat_map(range, fn n ->
            intent = intent(3, n)

            with {:ok, _, "prepared"} <- Owner.prepare(name, intent),
                 {:ok, :committed} <- Owner.observe(name, intent["operation_id"], :applied),
                 {:ok, [item]} <- Owner.delivery_batch(name),
                 {:ok, :committed} <-
                   Owner.acknowledge_delivery(name, item["operation_id"], item["intent_sha256"]) do
              []
            else
              other -> [{n, other}]
            end
          end)
        after
          Process.unregister(consumer)
        end
      end

      def intent(version, n) do
        id = "cap_" <> String.pad_leading(String.downcase(Integer.to_string(n, 16)), 32, "0")

        {:ok, intent} =
          AuditJournal.admit_intent(%{
            "version" => version,
            "kind" => "arbor.security.authority_mutation_intent.v#{version}",
            "operation" => "capability_grant",
            "effect_class" => "authority_increase",
            "authority_namespace" => "capability",
            "authority_key" => id,
            "before_fence" => %{"kind" => "absent"},
            "after_fingerprint" => %{
              "kind" => "live",
              "record_id" => "record-#{n}",
              "generation" => 1,
              "revision" => 1,
              "capability_digest" => String.duplicate("ab", 32)
            },
            "audit" => %{
              "event_type" => "capability_granted",
              "data" => %{
                "capability_id" => id,
                "principal_id" => "agent_fixture",
                "resource_uri" => "arbor://memory/read"
              }
            },
            "prepared_at" => @time
          })

        intent
      end

      def prepared_record(intent) do
        %{
          "version" => 1,
          "kind" => AuditJournal.record_kind(),
          "record_type" => "prepared",
          "operation_id" => intent["operation_id"],
          "occurred_at" => intent["prepared_at"],
          "intent" => intent
        }
      end
    end

  @driver elem(driver, 1)
  @driver_binary elem(driver, 2)
  @owner :audit_retirement_peer_owner
  @consumer :audit_retirement_peer_consumer
  @wall_clock [["oldest_pending_age_seconds"], ["retirement", "oldest_prepared_age_seconds"]]

  test "a whole-BEAM restart reconstructs retirement status, floor and ledger; late inputs follow the crash table" do
    started_distributed = ensure_distributed_node()
    on_exit(fn -> if started_distributed, do: Node.stop() end)
    root = unique_root()
    opts = [mode: :durable, root: root, name: @owner, capacity_profile: :operational]

    {peer_a, node_a} = start_driver_peer!("audit_retire_a")
    assert {:ok, _pid} = :erpc.call(node_a, @driver, :start_owner, [opts], 120_000)
    assert [] = :erpc.call(node_a, @driver, :drive, [@owner, @consumer, 1..700], 600_000)

    assert {:ok, status_a} =
             :erpc.call(node_a, Arbor.Security.AuditJournalOwner, :status, [@owner])

    assert status_a["capacity"]["retired_operation_total"] == 512
    assert status_a["capacity"]["retirable_operation_count"] == 188
    assert status_a["capacity"]["retained_operation_count"] == 188
    assert status_a["retirement"]["floor"] == 3
    assert status_a["retirement"]["ledger_state"] == "bound"
    assert status_a["retirement"]["ledger_frames"] == 1
    assert status_a["pending_count"] == 0

    :ok = :peer.stop(peer_a)
    refute node_a in Node.list(:connected)

    {_peer_b, node_b} = start_driver_peer!("audit_retire_b")
    assert {:ok, _pid} = :erpc.call(node_b, @driver, :start_owner, [opts], 120_000)

    assert {:ok, status_b} =
             :erpc.call(node_b, Arbor.Security.AuditJournalOwner, :status, [@owner])

    assert drop_wall_clock(status_b) == drop_wall_clock(status_a)

    # Crash table B5 on the restarted BEAM.
    v2 = :erpc.call(node_b, @driver, :intent, [2, 1])
    retired_v3 = @driver.intent(3, 1)

    assert {:error, :retired_version} =
             :erpc.call(node_b, Arbor.Security.AuditJournalOwner, :append, [
               @owner,
               @driver.prepared_record(v2)
             ])

    new_grant = @driver.intent(3, 10_000)

    assert {:ok, _, "prepared"} =
             :erpc.call(node_b, Arbor.Security.AuditJournalOwner, :prepare, [@owner, new_grant])

    # Documented residual (H4): a retired v3 identity re-presented raw in-BEAM
    # is not remembered in the hot set and is admitted as a new operation; the
    # cold ledger keeps the original evidence for offline detection.
    assert {:ok, :committed} =
             :erpc.call(node_b, Arbor.Security.AuditJournalOwner, :append, [
               @owner,
               @driver.prepared_record(retired_v3)
             ])

    assert {:ok, after_b} =
             :erpc.call(node_b, Arbor.Security.AuditJournalOwner, :status, [@owner])

    assert after_b["pending_count"] == 2
    assert after_b["capacity"]["retired_operation_total"] == 512
  end

  # ---------------------------------------------------------------------------

  defp drop_wall_clock(status) do
    Enum.reduce(@wall_clock, status, fn path, acc -> put_in(acc, path, :wall_clock) end)
  end

  defp start_driver_peer!(prefix) do
    name = String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
    {:ok, peer, node} = start_peer(name)
    on_exit(fn -> safely_stop_peer(peer) end)
    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
    :ok = :erpc.call(node, :logger, :set_primary_config, [:level, :none])

    {:module, @driver} =
      :erpc.call(node, :code, :load_binary, [
        @driver,
        ~c"audit_retirement_peer_driver",
        @driver_binary
      ])

    :ok = :erpc.call(node, @driver, :boot, [@consumer], 60_000)
    {peer, node}
  end

  defp ensure_distributed_node do
    if Node.alive?() do
      false
    else
      epmd = System.find_executable("epmd") || flunk("epmd executable is unavailable")
      {_output, 0} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)

      name =
        String.to_atom(
          "audit_retire_test_#{System.unique_integer([:positive, :monotonic])}@localhost"
        )

      {:ok, _} = :net_kernel.start([name, :shortnames])
      true
    end
  end

  # As distributed_peer_integration_test.exs: lifecycle control on stdio,
  # then an explicit distribution connection.
  defp start_peer(name) do
    options = %{name: name, host: ~c"localhost", connection: :standard_io, args: []}

    with {:ok, peer, peer_node} <- :peer.start_link(options) do
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

  defp unique_root do
    dir =
      Path.join(
        System.tmp_dir!(),
        "audit-retire-peer-#{System.pid()}-#{System.unique_integer([:positive])}-" <>
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    {:ok, root} = SafePath.resolve_real(dir)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
