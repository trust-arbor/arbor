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

  test "non-authoritative event projection is an optional facade callback" do
    assert {:project_already_committed_events_into_backend, 4} in Persistence.behaviour_info(
             :callbacks
           )

    assert {:project_already_committed_events_into_backend, 4} in Persistence.behaviour_info(
             :optional_callbacks
           )
  end

  test "every EventLog facade callback stays optional so existing backends still load" do
    optional = Persistence.behaviour_info(:optional_callbacks)

    event_log_callbacks = [
      append_events_to_stream_using_backend: 5,
      reconcile_event_append_using_backend: 4,
      purge_complete_event_stream_using_backend: 4,
      check_complete_event_stream_absent_using_backend: 4,
      read_events_from_stream_using_backend: 4,
      read_current_stream_head_using_backend: 4,
      read_all_events_using_backend: 3,
      check_stream_exists_using_backend: 4,
      get_stream_version_using_backend: 4,
      list_all_streams_using_backend: 3,
      get_stream_count_using_backend: 3,
      get_event_count_using_backend: 3,
      project_already_committed_events_into_backend: 4
    ]

    for callback <- event_log_callbacks do
      assert callback in optional
    end
  end

  test "event projection error vocabulary names each conflicting identity surface" do
    source =
      File.read!(Path.expand("../../../../lib/arbor/contracts/api/persistence.ex", __DIR__))

    for reason <- [
          ":event_id_conflict",
          ":global_position_conflict",
          ":stream_position_conflict",
          ":projection_mode_required",
          ":projection_not_supported"
        ] do
      assert source =~ ~r/@type event_projection_error ::[\s\S]*?#{reason}/,
             "event_projection_error must include #{reason}"
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
