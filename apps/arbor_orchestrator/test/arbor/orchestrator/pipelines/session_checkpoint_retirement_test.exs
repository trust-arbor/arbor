defmodule Arbor.Orchestrator.Pipelines.SessionCheckpointRetirementTest do
  @moduledoc """
  Runs the production turn's blocked-input tail and an explicit legacy graph.

  Classification is a deterministic dependency fixture. The retained checkpoint
  syscall uses the real Actions facade. These tests prove
  graph retirement and truthful results, not Session restart durability.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator

  @moduletag :fast
  @moduletag :integration
  @turn_path Path.expand("../../../../specs/pipelines/session/turn.dot", __DIR__)

  defmodule ActionExecutor do
    def execute("session.classify", _params, _workdir, _opts) do
      {:ok, Jason.encode!(%{input_type: "blocked", block_reason: "test classification"})}
    end

    def execute(action, params, _workdir, opts)
        when action in ["session_memory.update", "session_memory.checkpoint"] do
      {:ok, module} = Arbor.Actions.name_to_module(action)

      context = %{
        agent_id: Keyword.fetch!(opts, :agent_id),
        memory_write_policy: Keyword.get(opts, :memory_write_policy)
      }

      case Arbor.Actions.execute_action(module, params, context) do
        {:ok, result} -> {:ok, Jason.encode!(result)}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end

    def execute(action, _params, _workdir, _opts),
      do: {:error, "Unexpected action in checkpoint regression: #{action}"}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "session_checkpoint_retirement_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    opts = [
      logs_root: root,
      resumable: false,
      authorization: false,
      actions_executor: ActionExecutor,
      memory_write_policy: :deny,
      initial_values: %{
        "session.agent_id" => "agent_checkpoint_retirement",
        "session.session_id" => "session_checkpoint_retirement",
        "session.turn_count" => 5,
        "session.input" => "blocked test input"
      }
    ]

    %{opts: opts}
  end

  test "checkpoint retirement regression: production turn finishes without claiming a Session checkpoint",
       %{opts: opts} do
    assert {:ok, result} = Orchestrator.run(File.read!(@turn_path), opts)
    assert result.final_outcome.status == :success
    assert "format_error" in result.completed_nodes
    refute "update_memory" in result.completed_nodes
    assert List.last(result.completed_nodes) == "done"
    refute "checkpoint" in result.completed_nodes
    refute Map.has_key?(result.context, "session.memory_updated")
    refute Map.has_key?(result.context, "session.last_checkpoint")
    assert result.context["session.response"] =~ "test classification"
  end

  test "checkpoint retirement regression: explicitly loaded legacy graph reports failure, never a saved marker",
       %{opts: opts} do
    legacy = """
    digraph LegacyCheckpoint {
      start [shape=Mdiamond]
      checkpoint [type="exec", target="action", action="session_memory.checkpoint",
        context_keys="session.session_id,session.turn_count", output_prefix="session"]
      done [shape=Msquare]
      start -> checkpoint -> done
    }
    """

    assert {:ok, result} = Orchestrator.run(legacy, opts)
    assert result.final_outcome.status == :fail
    assert result.final_outcome.failure_reason =~ "session_checkpoint_retired"
    refute Map.has_key?(result.context, "session.last_checkpoint")
  end
end
