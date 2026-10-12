defmodule Arbor.Orchestrator.Pipelines.HeartbeatParseStatusRegressionTest do
  @moduledoc """
  Regression (Imp review 2026-09-27, D1): in every heartbeat variant, a reply
  that fails to parse must reach the engine context marked as a parse failure
  while still executing no actions.

  Runs each variant's real `process` and `execute_actions` nodes through the
  engine (ExecHandler context-key binding into `session.process_results`, then
  `session_execution.execute_actions`), seeded with what `llm_call` leaves in
  `last_response`. Before the fix an unparseable reply produced the same
  context as an idle one: empty `session.actions` and nothing else.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :fast

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  @variants ~w(heartbeat.dot heartbeat-full.dot heartbeat-bare.dot heartbeat-goals.dot
               heartbeat-notes.dot heartbeat-identity.dot)

  setup do
    logs_root = Path.join(System.tmp_dir!(), "hb-parse-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(logs_root) end)
    %{logs_root: logs_root}
  end

  test "every heartbeat variant is covered" do
    on_disk =
      pipelines_dir()
      |> Path.join("heartbeat*.dot")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert on_disk == Enum.sort(@variants)
  end

  for variant <- @variants do
    @variant variant

    test "#{variant}: an unparseable reply runs no actions and is marked parse_failed", ctx do
      {context, log} =
        with_log(fn ->
          run_process_tail(@variant, "I will read lib/foo.ex next.", "reflection", ctx)
        end)

      assert context["session.parse_status"] == "parse_failed"
      assert context["session.parse_error"] == "not_json"
      assert context["session.actions"] == []
      assert context["session.has_action_results"] == false
      assert context["session.percepts"] == []
      assert log =~ "heartbeat reply did not parse (not_json)"
    end

    test "#{variant}: an idle reply is parsed with no error", ctx do
      idle = ~s({"thinking": "Nothing needs attention.", "actions": [], "memory_notes": []})
      context = run_process_tail(@variant, idle, "reflection", ctx)

      assert context["session.parse_status"] == "parsed"
      assert context["session.parse_error"] == nil
      assert context["session.actions"] == []
      assert context["session.has_action_results"] == false
    end
  end

  # start -> process -> execute_actions -> done, using the variant's own node attrs.
  defp run_process_tail(variant, reply, mode, ctx) do
    agent_id = "agent_hb_parse_#{System.unique_integer([:positive])}"

    # process_results and execute_actions are capability-gated. Assert the
    # grant so a refused fixture fails here with its reason, not later as
    # "unauthorized".
    assert {:ok, capability} =
             Arbor.Security.grant_fixture(
               principal: agent_id,
               resource: "arbor://orchestrator/execute/**"
             )

    on_exit(fn -> Arbor.Security.revoke_fixture(capability.id) end)

    assert {:ok, result} =
             Arbor.Orchestrator.run(process_tail(variant),
               agent_id: agent_id,
               execution_principal: agent_id,
               authorization: false,
               resumable: false,
               logs_root: ctx.logs_root,
               initial_values: %{
                 "session.agent_id" => agent_id,
                 "session.cognitive_mode" => mode,
                 "last_response" => reply
               }
             )

    assert result.final_outcome.status == :success, inspect(result.final_outcome)
    result.context
  end

  defp process_tail(filename) do
    {:ok, parsed} = filename |> dot_path() |> File.read!() |> Arbor.Orchestrator.parse()

    nodes = [
      Map.fetch!(parsed.nodes, "start"),
      Map.fetch!(parsed.nodes, "process"),
      Map.fetch!(parsed.nodes, "execute_actions"),
      Map.fetch!(parsed.nodes, "done")
    ]

    graph =
      Enum.reduce(nodes, %Graph{id: parsed.id, attrs: parsed.attrs}, &Graph.add_node(&2, &1))

    nodes
    |> Enum.map(fn %Node{id: id} -> id end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [from, to], acc -> Graph.add_edge(acc, %Edge{from: from, to: to}) end)
  end

  defp dot_path(filename), do: Path.join(pipelines_dir(), filename)

  defp pipelines_dir do
    [
      Path.join([File.cwd!(), "specs", "pipelines", "session"]),
      Path.join([File.cwd!(), "apps", "arbor_orchestrator", "specs", "pipelines", "session"])
    ]
    |> Enum.find(&File.dir?/1)
  end
end
