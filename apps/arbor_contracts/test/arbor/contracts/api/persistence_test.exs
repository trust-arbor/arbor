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
end
