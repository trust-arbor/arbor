defmodule Arbor.Agent.ExactTemplatePolicyTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.{ExactTemplatePolicy, TemplateStore}
  alias Arbor.Common.SafePath

  @moduletag :fast

  test "Pipeline Architect snapshot retains runtime defaults and canonicalizes a symlink repo root" do
    assert {:ok, data} = TemplateStore.resolve("pipeline_architect")

    actual_root =
      Path.join(System.tmp_dir!(), "arbor-exact-policy-#{System.unique_integer([:positive])}")

    link_root = actual_root <> "-link"
    File.mkdir_p!(actual_root)
    File.ln_s!(actual_root, link_root)

    on_exit(fn ->
      File.rm_rf(actual_root)
      File.rm(link_root)
    end)

    assert {:ok, envelope} =
             ExactTemplatePolicy.build("pipeline_architect", data, repo_root: link_root)

    assert {:ok, expected_root} = SafePath.resolve_real(actual_root)

    snapshot = ExactTemplatePolicy.snapshot(envelope)
    metadata = ExactTemplatePolicy.template_metadata(snapshot)
    uri_root = String.trim_leading(expected_root, "/")

    assert metadata["provider"] == "openai_oauth"
    assert metadata["model"] == "gpt-5.5"
    assert metadata["context_management"] == "heuristic"
    assert metadata["category"] == "specialized_agent"
    assert snapshot["repo_root"] == expected_root

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
    repo_root = File.cwd!() |> Path.expand()

    assert {:ok, envelope} =
             ExactTemplatePolicy.build("pipeline_architect", data, repo_root: repo_root)

    metadata = ExactTemplatePolicy.put_metadata(%{}, envelope)

    assert {:ok, ^envelope} =
             ExactTemplatePolicy.validate("pipeline_architect", metadata, data,
               repo_root: repo_root
             )
  end

  test "non-exact template data does not require a repo-root snapshot" do
    assert {:ok, data} = TemplateStore.resolve("conversationalist")
    refute ExactTemplatePolicy.exact?(data)
  end
end
