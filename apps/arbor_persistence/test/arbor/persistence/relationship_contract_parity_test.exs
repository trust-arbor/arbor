defmodule Arbor.Persistence.RelationshipContractParityTest do
  @moduledoc """
  Short-form vs long-form Persistence relationship API parity (F-005 / VP-05D2C3I0A).
  """

  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Persistence

  @moduletag :integration
  @moduletag :database
  @moduletag spec: "VP-05D2C3I0A"

  setup do
    agent = "rel_parity_agent"
    :ok = Persistence.delete_all_relationships(agent)
    {:ok, agent: agent}
  end

  defp attrs(name) do
    %{
      id: "rel_parity_" <> name,
      name: name,
      preferred_name: nil,
      background: [],
      values: [],
      connections: [],
      key_moments: [],
      relationship_dynamic: nil,
      personal_details: [],
      current_focus: [],
      uncertainties: [],
      first_encountered: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      last_interaction: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      salience: 0.7,
      access_count: 0
    }
  end

  test "long-form exports exist and match short-form results", %{agent: agent} do
    assert function_exported?(Persistence, :upsert_tenant_relationship_record_for_agent, 2)

    assert function_exported?(
             Persistence,
             :retrieve_tenant_relationship_record_by_id_for_agent,
             3
           )

    assert function_exported?(Persistence, :list_tenant_relationship_records_for_agent, 2)
    assert function_exported?(Persistence, :delete_all_tenant_relationship_records_for_agent, 2)
    assert function_exported?(Persistence, :check_tenant_relationship_records_absent_for_agent, 2)

    assert {:ok, alpha} =
             Persistence.upsert_tenant_relationship_record_for_agent(agent, attrs("Alpha"))

    assert alpha.name == "Alpha"

    assert Persistence.fetch_relationship(agent, alpha.id) ==
             Persistence.retrieve_tenant_relationship_record_by_id_for_agent(agent, alpha.id, [])

    assert Persistence.fetch_relationship_by_name(agent, "Alpha") ==
             Persistence.retrieve_tenant_relationship_record_by_name_for_agent(
               agent,
               "Alpha",
               []
             )

    assert Persistence.list_relationships(agent, sort_by: :name, sort_dir: :asc) ==
             Persistence.list_tenant_relationship_records_for_agent(agent,
               sort_by: :name,
               sort_dir: :asc
             )

    assert Persistence.count_relationships(agent) ==
             Persistence.count_tenant_relationship_records_for_agent(agent, [])

    assert Persistence.fetch_primary_relationship(agent) ==
             Persistence.retrieve_primary_tenant_relationship_record_for_agent(agent, [])

    assert {:ok, touched} =
             Persistence.touch_tenant_relationship_record_for_agent(agent, alpha.id, [])

    assert touched.access_count >= 1

    assert {:ok, updated} =
             Persistence.update_tenant_relationship_record_for_agent(
               agent,
               alpha.id,
               %{salience: 0.95},
               []
             )

    assert updated.salience == 0.95

    assert {:ok, beta} = Persistence.put_relationship(agent, attrs("Beta"))

    assert :ok =
             Persistence.delete_tenant_relationship_record_for_agent(agent, beta.id, [])

    assert {:error, :not_found} = Persistence.fetch_relationship(agent, beta.id)

    assert :ok = Persistence.delete_all_tenant_relationship_records_for_agent(agent, [])

    assert Persistence.relationships_absent?(agent) ==
             Persistence.check_tenant_relationship_records_absent_for_agent(agent, [])

    assert {:ok, true} = Persistence.relationships_absent?(agent)
  end

  test "long-form trailing opts are closed allowlists; invalid opts fail closed", %{agent: agent} do
    assert {:ok, alpha} =
             Persistence.upsert_tenant_relationship_record_for_agent(agent, attrs("OptsAlpha"))

    # Empty allowlist ops: non-empty keyword is rejected (not silently ignored).
    empty_opt_callers = [
      fn ->
        Persistence.retrieve_tenant_relationship_record_by_id_for_agent(agent, alpha.id, foo: 1)
      end,
      fn ->
        Persistence.retrieve_tenant_relationship_record_by_name_for_agent(agent, "OptsAlpha",
          foo: 1
        )
      end,
      fn ->
        Persistence.update_tenant_relationship_record_for_agent(
          agent,
          alpha.id,
          %{salience: 0.5},
          foo: 1
        )
      end,
      fn ->
        Persistence.delete_tenant_relationship_record_for_agent(agent, alpha.id, foo: 1)
      end,
      fn ->
        Persistence.touch_tenant_relationship_record_for_agent(agent, alpha.id, foo: 1)
      end,
      fn -> Persistence.count_tenant_relationship_records_for_agent(agent, foo: 1) end,
      fn ->
        Persistence.retrieve_primary_tenant_relationship_record_for_agent(agent, foo: 1)
      end,
      fn -> Persistence.delete_all_tenant_relationship_records_for_agent(agent, foo: 1) end,
      fn -> Persistence.check_tenant_relationship_records_absent_for_agent(agent, foo: 1) end
    ]

    for caller <- empty_opt_callers do
      assert {:error, :invalid_options} = caller.()
    end

    # Non-list / non-keyword / duplicate keys rejected across long-form surface.
    for bad <- [:not_a_list, [{"string", 1}], [foo: 1, foo: 2]] do
      assert {:error, :invalid_options} =
               Persistence.retrieve_tenant_relationship_record_by_id_for_agent(
                 agent,
                 alpha.id,
                 bad
               )

      assert {:error, :invalid_options} =
               Persistence.count_tenant_relationship_records_for_agent(agent, bad)

      assert {:error, :invalid_options} =
               Persistence.list_tenant_relationship_records_for_agent(agent, bad)
    end

    # List allowlist admits known keys only.
    assert {:error, :invalid_options} =
             Persistence.list_tenant_relationship_records_for_agent(agent, unknown: true)

    assert {:ok, _} =
             Persistence.list_tenant_relationship_records_for_agent(agent,
               sort_by: :name,
               sort_dir: :asc,
               limit: 10
             )

    # Valid empty opts still succeed (parity with short form).
    assert Persistence.fetch_relationship(agent, alpha.id) ==
             Persistence.retrieve_tenant_relationship_record_by_id_for_agent(
               agent,
               alpha.id,
               []
             )

    assert Persistence.count_relationships(agent) ==
             Persistence.count_tenant_relationship_records_for_agent(agent, [])
  end
end
