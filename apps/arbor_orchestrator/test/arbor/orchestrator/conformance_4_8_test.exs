defmodule Arbor.Orchestrator.Conformance48Test do
  use ExUnit.Case, async: false

  test "4.8 wait_all returns partial_success when any branch fails" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all"]
      a [label="A"]
      b [label="B"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]
      start -> parallel
      parallel -> a
      parallel -> b
      a -> join
      b -> join
      join -> exit [condition="outcome=success"]
    }
    """

    branch_executor = fn branch_id, _context, _graph, _opts ->
      if branch_id == "a",
        do: %{"id" => branch_id, "status" => "success", "score" => 0.8},
        else: %{"id" => branch_id, "status" => "fail", "score" => 0.1}
    end

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_4_8_wait_all_#{System.unique_integer([:positive])}"
      )

    assert {:ok, result} =
             Arbor.Orchestrator.run(dot,
               parallel_branch_executor: branch_executor,
               logs_root: logs_root
             )

    assert result.context["parallel.success_count"] == 1
    assert result.context["parallel.fail_count"] == 1

    {:ok, status_json} = File.read(Path.join([logs_root, "parallel", "status.json"]))
    {:ok, status} = Jason.decode(status_json)
    assert status["outcome"] == "partial_success"
  end

  test "4.8 k_of_n and quorum policies are evaluated from branch counts" do
    k_of_n = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="k_of_n", join_k=2]
      a [label="A"]
      b [label="B"]
      c [label="C"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]
      start -> parallel
      parallel -> a
      parallel -> b
      parallel -> c
      a -> join
      b -> join
      c -> join
      join -> exit
    }
    """

    quorum = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="quorum", quorum_fraction=0.7]
      a [label="A"]
      b [label="B"]
      c [label="C"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]
      start -> parallel
      parallel -> a
      parallel -> b
      parallel -> c
      a -> join
      b -> join
      c -> join
      join -> exit [condition="outcome=success"]
    }
    """

    branch_executor = fn branch_id, _context, _graph, _opts ->
      case branch_id do
        "a" -> %{"id" => "a", "status" => "success", "score" => 0.9}
        "b" -> %{"id" => "b", "status" => "success", "score" => 0.8}
        _ -> %{"id" => "c", "status" => "fail", "score" => 0.1}
      end
    end

    assert {:ok, k_result} =
             Arbor.Orchestrator.run(k_of_n, parallel_branch_executor: branch_executor)

    assert "exit" in k_result.completed_nodes

    assert {:ok, q_result} =
             Arbor.Orchestrator.run(quorum, parallel_branch_executor: branch_executor)

    # quorum 0.7 with 2/3 success should fail and not reach conditional exit edge.
    refute "exit" in q_result.completed_nodes
  end

  test "4.8 first_success succeeds when any branch succeeds" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="first_success"]
      a [label="A"]
      b [label="B"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]
      start -> parallel
      parallel -> a
      parallel -> b
      a -> join
      b -> join
      join -> exit
    }
    """

    branch_executor = fn branch_id, _context, _graph, _opts ->
      if branch_id == "a",
        do: %{"id" => "a", "status" => "fail", "score" => 0.1},
        else: %{"id" => "b", "status" => "success", "score" => 0.8}
    end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, parallel_branch_executor: branch_executor)
    assert "exit" in result.completed_nodes
  end

  test "4.8 error_policy fail_fast stops processing after first failed branch" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all", error_policy="fail_fast"]
      a [label="A"]
      b [label="B"]
      c [label="C"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]
      start -> parallel
      parallel -> a
      parallel -> b
      parallel -> c
      a -> join
      b -> join
      c -> join
      join -> exit [condition="outcome=success"]
    }
    """

    parent = self()

    branch_executor = fn branch_id, _context, _graph, _opts ->
      send(parent, {:branch_called, branch_id})
      %{"id" => branch_id, "status" => "fail", "score" => 0.0}
    end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, parallel_branch_executor: branch_executor)
    assert_receive {:branch_called, "a"}
    refute_receive {:branch_called, "b"}
    refute_receive {:branch_called, "c"}
    assert result.context["parallel.total_count"] == 1
  end

  test "4.8 error_policy ignore drops failed branches from results" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      parallel [shape=component, join_policy="wait_all", error_policy="ignore"]
      a [label="A"]
      b [label="B"]
      join [shape=tripleoctagon]
      exit [shape=Msquare]
      start -> parallel
      parallel -> a
      parallel -> b
      a -> join
      b -> join
      join -> exit
    }
    """

    branch_executor = fn branch_id, _context, _graph, _opts ->
      if branch_id == "a",
        do: %{"id" => "a", "status" => "success", "score" => 0.6},
        else: %{"id" => "b", "status" => "fail", "score" => 0.1}
    end

    assert {:ok, result} = Arbor.Orchestrator.run(dot, parallel_branch_executor: branch_executor)
    assert result.context["parallel.success_count"] == 1
    assert result.context["parallel.fail_count"] == 0
    assert length(result.context["parallel.results"]) == 1
    assert "exit" in result.completed_nodes
  end
end
