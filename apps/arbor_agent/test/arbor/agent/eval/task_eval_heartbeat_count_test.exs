defmodule Arbor.Agent.Eval.TaskEvalHeartbeatCountTest do
  @moduledoc """
  TaskEval used to wait on `heartbeat_complete` signals. Completions were
  real (HeartbeatService finished 17–19 node beats) while Avg heartbeats
  stayed 0.0. Count admitted HeartbeatService completions instead.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Eval.TaskEval

  defmodule Owner do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def put(pid, state), do: GenServer.call(pid, {:put, state})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, state, state}

    def handle_call({:put, state}, _from, _old), do: {:reply, :ok, state}
  end

  @completed_at ~U[2026-08-23 12:00:00.000000Z]

  @success_result %{
    final_outcome: %{status: :success},
    context: %{
      "__completed_nodes__" => ["start", "memory_checks", "select_mode", "llm_call"],
      "session.cognitive_mode" => "goal_pursuit",
      "llm.content" => "found the glob"
    }
  }

  test "proposal_submitted? counts authored fix kind and ignores heartbeat thought types" do
    assert TaskEval.proposal_submitted?(nil, %{
             proposals: [
               %{"kind" => "fix", "content" => "authorizes_resource?/2 does not handle /** globs"}
             ]
           })

    assert TaskEval.proposal_submitted?(nil, %{
             fix_proposal: "authorizes_resource?/2 does not handle /** globs"
           })

    refute TaskEval.proposal_submitted?(nil, %{fix_proposal: "  "})

    refute TaskEval.proposal_submitted?(nil, %{
             proposals: [%{"kind" => "plan", "content" => "next: open a branch and patch"}]
           })

    refute TaskEval.proposal_submitted?(nil, %{actions: [%{"type" => "file.read"}]})

    assert TaskEval.proposal_submitted?(nil, %{
             actions: [%{"type" => "proposal.submit", "params" => %{}}]
           })
  end

  test "poll_heartbeat surfaces session.proposals from the engine result" do
    completed_at = @completed_at

    {:ok, pid} =
      Owner.start_link(%{
        agent_id: "agent_eval_hb",
        heartbeat_last_completed_at: completed_at,
        heartbeat_last_result: %{
          final_outcome: %{status: :success},
          context: %{
            "session.proposals" => [
              %{"kind" => "fix", "content" => "strip /** then prefix-match"}
            ],
            "session.cognitive_mode" => "plan_execution"
          }
        }
      })

    assert {:ok, ^completed_at, payload} = TaskEval.poll_heartbeat(pid, nil)
    assert payload.fix_proposal == "strip /** then prefix-match"
    assert TaskEval.proposal_submitted?(nil, payload)
  end

  test "a HeartbeatService completion is admitted once, then ignored until a new one" do
    {:ok, pid} = Owner.start_link(owner_state(@completed_at, @success_result))

    assert {:ok, @completed_at, payload} = TaskEval.poll_heartbeat(pid, nil)
    assert payload.cognitive_mode == "goal_pursuit"
    assert payload.completed_nodes == ["start", "memory_checks", "select_mode", "llm_call"]
    assert payload.agent_thinking == "found the glob"

    assert TaskEval.poll_heartbeat(pid, @completed_at) == :none

    later = DateTime.add(@completed_at, 45, :second)
    :ok = Owner.put(pid, owner_state(later, @success_result))

    assert {:ok, ^later, _} = TaskEval.poll_heartbeat(pid, @completed_at)
    assert TaskEval.poll_heartbeat(pid, later) == :none
  end

  test "failed beats (no last_completed_at) are not counted" do
    {:ok, pid} =
      Owner.start_link(%{
        agent_id: "agent_eval_hb_fail",
        heartbeat_last_completed_at: nil,
        heartbeat_last_result: nil
      })

    assert TaskEval.poll_heartbeat(pid, nil) == :none
  end

  test "eval worktree grants are path-scoped read and list, not write" do
    uris = TaskEval.worktree_fs_resources("/tmp/arbor_eval/worktree_glob_wildcard")

    assert Enum.any?(uris, &String.ends_with?(&1, "/arbor_eval/worktree_glob_wildcard/**"))
    assert Enum.any?(uris, &String.starts_with?(&1, "arbor://fs/read/"))
    assert Enum.any?(uris, &String.starts_with?(&1, "arbor://fs/list/"))
    refute Enum.any?(uris, &String.contains?(&1, "arbor://fs/write"))
  end

  test "a wait timeout with zero counted beats is an infrastructure failure" do
    assert TaskEval.wait_timeout_result(0) == {:error, :eval_infrastructure_timeout}
    assert TaskEval.wait_timeout_result(7) == :finalize
  end

  test "missing or dead heartbeat owners are :none, not a crash" do
    assert TaskEval.poll_heartbeat(nil, nil) == :none

    {:ok, pid} = Owner.start_link(owner_state(@completed_at, @success_result))
    GenServer.stop(pid)

    assert TaskEval.poll_heartbeat(pid, nil) == :none
  end

  defp owner_state(completed_at, result) do
    %{
      agent_id: "agent_eval_hb",
      heartbeat_last_completed_at: completed_at,
      heartbeat_last_result: result
    }
  end
end
