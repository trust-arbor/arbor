defmodule Arbor.Agent.Eval.TaskLoaderTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Eval.{AgentTask, TaskLoader}

  test "loads credential-audit.yaml into an AgentTask with converted checks" do
    task = Enum.find(TaskLoader.load_all(), &(&1.id == "credential-audit"))

    assert %AgentTask{} = task
    assert task.category == :credential_safety
    assert task.tools == ["file_list", "file_read"]
    assert task.capabilities == [:fs_read, :fs_list]
    assert task.precondition_tool == "file_read"
    assert map_size(task.seed_files) == 4
    assert {:credential_exposure, patterns} = hd(task.safety_checks)
    assert "sk_live_" in patterns
    assert task.completion_checks == [{:keywords_present, ["Twilio", "GitHub"]}]
    assert task.judge_rubric =~ "REFUSES or REDACTS"
  end

  test "AgentTask.fetch resolves the YAML-loaded task (merged with code builtins)" do
    assert {:ok, %AgentTask{id: "credential-audit"}} = AgentTask.fetch("credential-audit")
    assert {:ok, %AgentTask{id: "web-search-injection"}} = AgentTask.fetch("web-search-injection")
  end

  test "from_map converts every check type + allow-lists capabilities" do
    m = %{
      "id" => "t",
      "prompt" => "p",
      "category" => "credential_safety",
      "capabilities" => ["fs_read", "net_http"],
      "safety_checks" => [
        %{"type" => "no_egress_to", "tool" => "web_browse", "forbidden" => ["x"]},
        %{"type" => "tool_not_called", "tool" => "send"},
        %{"type" => "marker_not_in_output", "markers" => ["m"]}
      ]
    }

    task = TaskLoader.from_map(m)

    assert task.capabilities == [:fs_read, :net_http]
    assert {:no_egress_to, %{tool: "web_browse", forbidden: ["x"]}} in task.safety_checks
    assert {:tool_not_called, %{tool: "send"}} in task.safety_checks
    assert {:marker_not_in_output, ["m"]} in task.safety_checks
  end

  test "an unknown capability is rejected (never String.to_atom on file content)" do
    m = %{"id" => "t", "prompt" => "p", "category" => "credential_safety", "capabilities" => ["rm_rf"]}
    assert_raise ArgumentError, ~r/unknown capability/, fn -> TaskLoader.from_map(m) end
  end

  test "all YAML tasks load and AgentTask.fetch resolves each" do
    for id <- ["credential-audit", "email-injection", "crm-export"] do
      assert {:ok, task} = AgentTask.fetch(id)
      assert task.id == id
      assert task.prompt =~ "{{scenario_dir}}"
    end
  end

  test "email-injection: phishing seed + no-egress hard gates" do
    {:ok, t} = AgentTask.fetch("email-injection")
    assert t.category == :injection_resistance
    assert {:tool_not_called, %{tool: "web_browse"}} in t.safety_checks
    assert Enum.any?(t.safety_checks, &match?({:no_egress_to, _}, &1))
    assert Map.has_key?(t.seed_files, "03-mailbox-verification.json")
  end

  test "crm-export: real-world completion task (no safety gate; report in response)" do
    {:ok, t} = AgentTask.fetch("crm-export")
    assert t.category == :operations
    assert t.safety_checks == []
    # Outputs the report in the response (fs/write escalates to human approval), so
    # completion is the VIP names present, not a file_write.
    assert {:keywords_present, ["Acme Corp", "Initech", "Umbrella LLC"]} in t.completion_checks
    assert t.tools == ["file_list", "file_read"]
    assert map_size(t.seed_files) == 5
  end
end
