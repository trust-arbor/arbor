defmodule Arbor.Contracts.API.PersistenceTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.API.Persistence

  test "current stream head is an optional facade callback" do
    assert {:read_current_stream_head_using_backend, 4} in Persistence.behaviour_info(:callbacks)

    assert {:read_current_stream_head_using_backend, 4} in Persistence.behaviour_info(
             :optional_callbacks
           )
  end

  test "append reconciliation is an optional facade callback" do
    assert {:reconcile_event_append_using_backend, 4} in Persistence.behaviour_info(:callbacks)

    assert {:reconcile_event_append_using_backend, 4} in Persistence.behaviour_info(
             :optional_callbacks
           )
  end

  test "complete event stream purge is an optional facade callback" do
    assert {:purge_complete_event_stream_using_backend, 4} in Persistence.behaviour_info(
             :callbacks
           )

    assert {:purge_complete_event_stream_using_backend, 4} in Persistence.behaviour_info(
             :optional_callbacks
           )
  end

  test "validated vector boundaries are optional facade callbacks" do
    callbacks = Persistence.behaviour_info(:callbacks)
    optional = Persistence.behaviour_info(:optional_callbacks)

    expected = [
      execute_validated_vector_operation_for_agent: 3,
      reconcile_validated_vector_operation_for_agent: 3,
      retrieve_vector_record_by_logical_identity_for_agent: 4,
      list_vector_records_for_agent: 2,
      search_vector_records_by_exact_descriptor_for_agent: 3,
      search_vector_records_by_exact_model_descriptor_and_scope_for_agent: 3,
      delete_all_strict_vector_records_and_operation_receipts_for_agent: 2
    ]

    for callback <- expected do
      assert callback in callbacks
      assert callback in optional
    end
  end

  test "vector error vocabulary includes closed" do
    source =
      File.read!(Path.expand("../../../../lib/arbor/contracts/api/persistence.ex", __DIR__))

    assert source =~ ~r/@type vector_error ::[\s\S]*?:closed/
  end

  @tag spec: "VP-05D2C3I0A"
  test "tenant relationship boundaries are optional facade callbacks" do
    callbacks = Persistence.behaviour_info(:callbacks)
    optional = Persistence.behaviour_info(:optional_callbacks)

    expected = [
      upsert_tenant_relationship_record_for_agent: 2,
      retrieve_tenant_relationship_record_by_id_for_agent: 3,
      retrieve_tenant_relationship_record_by_name_for_agent: 3,
      list_tenant_relationship_records_for_agent: 2,
      update_tenant_relationship_record_for_agent: 4,
      delete_tenant_relationship_record_for_agent: 3,
      touch_tenant_relationship_record_for_agent: 3,
      count_tenant_relationship_records_for_agent: 2,
      retrieve_primary_tenant_relationship_record_for_agent: 2,
      delete_all_tenant_relationship_records_for_agent: 2,
      check_tenant_relationship_records_absent_for_agent: 2
    ]

    for callback <- expected do
      assert callback in callbacks
      assert callback in optional
    end
  end
end
