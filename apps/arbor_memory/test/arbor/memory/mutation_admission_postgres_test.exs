defmodule Arbor.Memory.MutationAdmissionPostgresTest do
  @moduledoc """
  Isolated real QueryableStore smoke for mutation admission (VP-05D2C3I1A).
  """

  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :integration
  @moduletag packet: "VP-05D2C3I1A"

  alias Arbor.Memory.MutationAdmission
  alias Arbor.Persistence.QueryableStore.Postgres
  alias Arbor.Persistence.Repo

  if Code.ensure_loaded?(Repo) and function_exported?(Repo, :__adapter__, 0) and
       Repo.__adapter__() != Ecto.Adapters.Postgres do
    @moduletag skip: "mutation admission postgres smoke requires ARBOR_DB=postgres"
  end

  @shell_id :ma_pg_shell

  setup do
    registry = :"ma_pg_reg_#{System.unique_integer([:positive])}"
    sup = :"ma_pg_sup_#{System.unique_integer([:positive])}"
    server = :"ma_pg_srv_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry}, id: {:ma_pg_reg, registry})

    start_supervised!(%{
      id: {:ma_pg_gsup, sup},
      start:
        {DynamicSupervisor, :start_link,
         [[name: sup, strategy: :one_for_one, max_children: 4096]]}
    })

    runtime_fp =
      Base.encode16(:crypto.hash(:sha256, "pg-rt-#{System.unique_integer()}"), case: :lower)

    start_shell!(server, registry, sup, runtime_fp)

    agent_id = "ma_pg_agent_#{System.unique_integer([:positive])}"

    {:ok,
     server: server, agent_id: agent_id, registry: registry, sup: sup, runtime_fp: runtime_fp}
  end

  defp start_shell!(server, registry, sup, runtime_fp) do
    start_supervised!(
      {MutationAdmission,
       [
         name: server,
         registry: registry,
         guardian_supervisor: sup,
         target: %{
           namespace: :memory_mutation_admission,
           backend: Postgres,
           opts: [repo: Repo]
         },
         runtime_fp: runtime_fp
       ]},
      id: @shell_id
    )
  end

  defp restart_shell!(server, registry, sup, runtime_fp) do
    case stop_supervised(@shell_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    start_shell!(server, registry, sup, runtime_fp)
  end

  @tag packet: "VP-05D2C3I1A"
  test "acquire, restart same runtime, drain, fence rotation, destroyed", %{
    server: server,
    agent_id: agent_id,
    registry: registry,
    sup: sup,
    runtime_fp: runtime_fp
  } do
    assert {:ok, %{durability: :node_restart}} =
             MutationAdmission.readiness(server: server)

    assert {:ok, lease} = MutationAdmission.acquire(agent_id, server: server)
    assert :ok = MutationAdmission.release(lease, server: server)

    # Restart MutationAdmission with the same runtime identity (packet smoke).
    restart_shell!(server, registry, sup, runtime_fp)

    assert {:ok, %{durability: :node_restart}} =
             MutationAdmission.readiness(server: server)

    assert {:ok, fence1} = MutationAdmission.drain(agent_id, server: server, timeout_ms: 2_000)
    assert {:ok, fence2} = MutationAdmission.drain(agent_id, server: server, timeout_ms: 2_000)
    assert fence1.token != fence2.token
    assert fence1.fence_generation != fence2.fence_generation
    assert {:error, :stale_fence} = MutationAdmission.mark_destroyed(fence1, server: server)
    assert :ok = MutationAdmission.mark_destroyed(fence2, server: server)
    assert :ok = MutationAdmission.mark_destroyed(fence2, server: server)
    assert {:error, :destroyed} = MutationAdmission.acquire(agent_id, server: server)
  end
end
