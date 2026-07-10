defmodule Arbor.Agent.ExactTemplatePolicyTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{ExactTemplatePolicy, TemplateStore}

  @moduletag :fast

  test "Pipeline Architect snapshot retains runtime defaults and fixes repo-scoped resources" do
    assert {:ok, data} = TemplateStore.resolve("pipeline_architect")

    repo_root = Path.expand("/tmp/arbor-exact-policy-root")

    assert {:ok, envelope} =
             ExactTemplatePolicy.build("pipeline_architect", data, repo_root: repo_root)

    snapshot = ExactTemplatePolicy.snapshot(envelope)
    metadata = ExactTemplatePolicy.template_metadata(snapshot)
    uri_root = String.trim_leading(repo_root, "/")

    assert metadata["provider"] == "openai_oauth"
    assert metadata["model"] == "gpt-5.5"
    assert metadata["context_management"] == "heuristic"
    assert metadata["category"] == "specialized_agent"
    assert snapshot["repo_root"] == repo_root

    assert Enum.map(ExactTemplatePolicy.capabilities(snapshot), & &1["resource"]) == [
             "arbor://fs/list",
             "arbor://fs/list/#{uri_root}/**",
             "arbor://fs/read",
             "arbor://fs/read/#{uri_root}/**",
             "arbor://orchestrator/execute",
             "arbor://orchestrator/execute/compute",
             "arbor://orchestrator/execute/exec",
             "arbor://orchestrator/execute/transform",
             "arbor://orchestrator/execute/unknown"
           ]
  end

  test "stored repo root validates independently of the current working directory" do
    assert {:ok, data} = TemplateStore.resolve("pipeline_architect")
    repo_root = Path.expand("/tmp/arbor-exact-policy-root")

    assert {:ok, envelope} =
             ExactTemplatePolicy.build("pipeline_architect", data, repo_root: repo_root)

    metadata = ExactTemplatePolicy.put_metadata(%{}, envelope)

    assert {:ok, ^envelope} =
             ExactTemplatePolicy.validate("pipeline_architect", metadata, data,
               repo_root: repo_root
             )
  end
end
