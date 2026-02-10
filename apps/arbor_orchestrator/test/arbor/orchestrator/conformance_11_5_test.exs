defmodule Arbor.Orchestrator.Conformance115Test do
  use ExUnit.Case, async: true

  test "11.5 retries RETRY outcomes up to max_retries then returns fail" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="retry", max_retries=1, retry_initial_delay_ms=1]
      exit [shape=Msquare]
      start -> flaky
      flaky -> exit [condition="outcome=fail"]
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: fn _ -> :ok end)

    assert result.final_outcome.status == :success
    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 1}}
    assert_receive {:event, %{type: :stage_failed, node_id: "flaky", will_retry: false}}
  end

  test "11.5 retries FAIL outcomes up to max_retries before final FAIL routing" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      flaky [simulate="fail", max_retries=2, retry_initial_delay_ms=1]
      fail_path [label="fail path"]
      exit [shape=Msquare]
      start -> flaky
      flaky -> fail_path [condition="outcome=fail"]
      fail_path -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: fn _ -> :ok end)

    assert "fail_path" in result.completed_nodes
    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 1}}
    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 2}}
    assert_receive {:event, %{type: :stage_failed, node_id: "flaky", will_retry: false}}
  end
end
