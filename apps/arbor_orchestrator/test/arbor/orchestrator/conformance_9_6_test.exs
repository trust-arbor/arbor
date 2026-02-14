defmodule Arbor.Orchestrator.Conformance96Test do
  use ExUnit.Case, async: false

  test "9.6 emits pipeline, stage, parallel, interview, and checkpoint events" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Proceed?", fan_out="false"]
      parallel [shape=component, fan_out="false"]
      a [label="A"]
      b [label="B"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]

      start -> gate
      gate -> parallel [label="[Y] Proceed"]
      gate -> exit [label="[N] Stop"]
      parallel -> a
      parallel -> b
      a -> join
      b -> join
      join -> exit
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end
    interviewer = fn _question -> %{value: "Y"} end

    branch_executor = fn branch_id, _context, _graph, _opts ->
      Process.sleep(5)

      %{
        "id" => branch_id,
        "status" => "success",
        "score" => if(branch_id == "a", do: 0.1, else: 0.9)
      }
    end

    assert {:ok, _result} =
             Arbor.Orchestrator.run(dot,
               on_event: on_event,
               interviewer: interviewer,
               parallel_branch_executor: branch_executor
             )

    assert_receive {:event, %{type: :pipeline_started}}
    assert_receive {:event, %{type: :stage_started, node_id: "start"}}
    assert_receive {:event, %{type: :stage_completed, node_id: "start", status: :success}}
    assert_receive {:event, %{type: :interview_started, stage: "gate"}}
    assert_receive {:event, %{type: :interview_completed, stage: "gate", selected: "parallel"}}
    assert_receive {:event, %{type: :parallel_started, node_id: "parallel", branch_count: 2}}
    assert_receive {:event, %{type: :parallel_branch_started, node_id: "parallel", branch: "a"}}
    assert_receive {:event, %{type: :parallel_branch_started, node_id: "parallel", branch: "b"}}
    assert_receive {:event, %{type: :parallel_branch_completed, node_id: "parallel", branch: "a"}}
    assert_receive {:event, %{type: :parallel_branch_completed, node_id: "parallel", branch: "b"}}
    assert_receive {:event, %{type: :parallel_completed, node_id: "parallel", success_count: 2}}
    assert_receive {:event, %{type: :checkpoint_saved, node_id: "parallel"}}
    assert_receive {:event, %{type: :pipeline_completed}}
  end

  test "9.6 emits retrying and failed stage events" do
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

    assert {:ok, _result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, sleep_fn: fn _ -> :ok end)

    assert_receive {:event, %{type: :stage_retrying, node_id: "flaky", attempt: 1}}
    assert_receive {:event, %{type: :stage_failed, node_id: "flaky", will_retry: false}}
  end

  test "9.6 emits interview timeout event when interviewer times out" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Proceed?", human.default_choice="exit", human.timeout_seconds=1.0, fan_out="false"]
      exit [shape=Msquare]
      start -> gate
      gate -> exit [label="[Y] Exit"]
    }
    """

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end
    interviewer = fn _question -> :timeout end

    assert {:ok, _result} =
             Arbor.Orchestrator.run(dot, on_event: on_event, interviewer: interviewer)

    assert_receive {:event, %{type: :interview_started, stage: "gate"}}
    assert_receive {:event, %{type: :interview_timeout, stage: "gate"}}
    assert_receive {:event, %{type: :interview_completed, stage: "gate", selected: "exit"}}
  end
end
