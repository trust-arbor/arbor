defmodule Arbor.Agent.Eval.TaskEvalCleanupTest do
  @moduledoc """
  TaskEval leftover-authority cleanup: OpenCode Zen probe ids are
  unregistered by agent_id, not left in Application env.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.Eval.TaskEval
  alias Arbor.LLM.OpenCodeZen

  test "cleanup_eval_principal unregisters the agent's OpenCode Zen probes" do
    agent_id = "agent_eval_cleanup_#{System.unique_integer([:positive])}"
    candidate = "unadmitted-eval-cleanup-#{System.unique_integer([:positive])}"

    on_exit(fn -> OpenCodeZen.unregister_eval_probes(agent_id) end)

    assert :ok = OpenCodeZen.register_eval_probes(agent_id, [candidate])
    assert OpenCodeZen.admit_model(candidate, agent_id: agent_id) == :ok

    assert :ok = TaskEval.cleanup_eval_principal(agent_id)

    assert OpenCodeZen.admit_model(candidate, agent_id: agent_id) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}
  end
end
