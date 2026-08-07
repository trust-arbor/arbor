defmodule Arbor.Memory.ProposalOwnerLifecycleTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.Proposal
  alias Arbor.Memory.Proposal.Store
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"
  @legacy_ets :arbor_memory_proposals

  setup do
    ensure_durable_store()
    ensure_legacy_table()
    ensure_store_running()
    agent_id = "prop_life_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      ensure_store_running()
      _ = Proposal.delete_all(agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "owner restart clears ephemeral queue and does not resurrect legacy ETS", %{
    agent_id: agent_id
  } do
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "ephemeral"})
    assert {:ok, _} = Proposal.get(agent_id, p.id)

    forged = %Proposal{
      id: p.id,
      agent_id: agent_id,
      type: :fact,
      content: "legacy resurrection attempt",
      confidence: 1.0,
      source: nil,
      evidence: [],
      metadata: %{},
      created_at: DateTime.utc_now(),
      status: :pending
    }

    :ets.insert(@legacy_ets, {{agent_id, p.id}, forged})

    pid = Process.whereis(Store)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    wait_until(fn ->
      case Process.whereis(Store) do
        new_pid when is_pid(new_pid) and new_pid != pid -> true
        _ -> false
      end
    end)

    assert {:error, :not_found} = Proposal.get(agent_id, p.id)
    assert Proposal.stats(agent_id).total == 0
    assert [{_, ^forged}] = :ets.lookup(@legacy_ets, {agent_id, p.id})
  end

  test "owner unavailable returns explicit error on public Proposal API" do
    assert Process.whereis(Store)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Store)
    assert Process.whereis(Store) == nil

    assert {:error, reason} = Proposal.create("agent_unavail", :fact, %{content: "x"})
    assert reason in [:store_unavailable, :request_expired]
  after
    ensure_store_running()
  end

  test "delete_agent_content is idempotent and absence is authoritative", %{agent_id: agent_id} do
    {:ok, _} = Proposal.create(agent_id, :fact, %{content: "one"})
    {:ok, _} = Proposal.create(agent_id, :insight, %{content: "two"})

    assert :ok = Proposal.delete_agent_content(agent_id)
    assert {:ok, true} = Proposal.agent_content_absent?(agent_id)
    assert :ok = Proposal.delete_agent_content(agent_id)
    assert {:ok, true} = Proposal.agent_content_absent?(agent_id)

    assert :ok = Proposal.delete_all(agent_id)
  end

  test "delete_all fails closed when owner is unavailable", %{agent_id: agent_id} do
    {:ok, _} = Proposal.create(agent_id, :fact, %{content: "present"})
    assert {:ok, false} = Proposal.agent_content_absent?(agent_id)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Store)
    assert Process.whereis(Store) == nil

    assert {:error, reason} = Proposal.delete_all(agent_id)
    assert reason in [:store_unavailable, :request_expired, :absence_uncertain]
  after
    ensure_store_running()
  end

  defp ensure_store_running do
    case Process.whereis(Store) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Store) do
          {:ok, _} ->
            :ok

          {:ok, _, _} ->
            :ok

          {:error, :running} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, :not_found} ->
            case Supervisor.start_child(Arbor.Memory.Supervisor, {Store, []}) do
              {:ok, _} ->
                :ok

              {:error, {:already_started, _}} ->
                :ok

              _ ->
                _ = Store.start_link([])
                :ok
            end

          _ ->
            _ = Store.start_link([])
            :ok
        end
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(20)
        wait_until(fun, attempts - 1)
      else
        flunk("condition not met")
      end
    end
  end

  defp ensure_legacy_table do
    case :ets.whereis(@legacy_ets) do
      :undefined -> :ets.new(@legacy_ets, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  defp ensure_durable_store do
    case Process.whereis(:arbor_memory_durable) do
      nil ->
        start_supervised!(
          {BufferedStore, name: :arbor_memory_durable, backend: nil, write_mode: :sync}
        )

      _ ->
        :ok
    end
  end
end
