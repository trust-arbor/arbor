defmodule Arbor.Commands.PlatformInventory.LLMScopePipelineSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.PlatformInventory
  alias Arbor.Commands.PlatformInventory.Scope

  @moduletag :fast
  @moduletag :security_regression
  @family [
    {"packages/arbor_llm/lib/arbor/llm/client.ex", "arbor_llm"},
    {"apps/arbor_llm_host/lib/arbor/llm/host.ex", "arbor_llm_host"},
    {"apps/arbor_orchestrator/lib/arbor/llm/arbor_actions_executor.ex", "arbor_orchestrator"},
    {"apps/arbor_commands/lib/mix/tasks/arbor.login.ex", "arbor_commands"},
    {"apps/arbor_commands/lib/mix/tasks/arbor.oauth.login.ex", "arbor_commands"},
    {"apps/arbor_commands/lib/mix/tasks/arbor/llm/free.ex", "arbor_commands"}
  ]

  test "security regression: public source inventory preserves the full LLM family without broad consumer selection" do
    root = repository!()
    for {path, _owner} <- @family, do: source!(root, path)
    git!(root, ["add", "."])

    assert {:ok, report} = PlatformInventory.run(root: root)

    assert Enum.sort(Enum.map(report["entries"], & &1["path"])) ==
             Enum.sort(Enum.map(@family, &elem(&1, 0)))

    assert Map.new(report["entries"], &{&1["path"], &1["app"]}) == Map.new(@family)
    assert report["schema"] == "arbor.packaging.platform_inventory.v2"
    assert report["counts"]["total_files"] == 6

    neighbors = [
      "packages/arbor_llm_other/lib/ignored.ex",
      "packages/arbor_llm/test/ignored.ex",
      "packages/arbor_support/lib/ignored.ex",
      "apps/arbor_llm_host_other/lib/ignored.ex",
      "apps/arbor_llm_host/priv/ignored.ex",
      "apps/arbor_llm_host/lib/ignored.exs",
      "apps/arbor_commands/lib/mix/tasks/arbor.login_extra.ex",
      "apps/arbor_commands/lib/mix/tasks/arbor.login.ex.extra.ex",
      "apps/arbor_commands/lib/mix/tasks/arbor/llm/unrelated.ex",
      "apps/arbor_commands/test/arbor.login.ex",
      "apps/arbor_orchestrator/lib/arbor/llm/arbor_actions_executor_extra.ex",
      "apps/arbor_orchestrator/lib/arbor/orchestrator/unrelated.ex",
      "packages/arbor_commands/lib/mix/tasks/arbor.login.ex"
    ]

    for path <- neighbors, do: source!(root, path)
    git!(root, ["add", "."])
    assert {:ok, with_neighbors} = PlatformInventory.run(root: root)
    assert with_neighbors["entries"] == report["entries"]
    for path <- neighbors, do: assert(match?({:error, _reason}, Scope.source_app(path)))
  end

  test "security regression: disclosure prompt production owner is inventoried without unrelated consumers" do
    root = repository!()
    prompt = "apps/arbor_commands/lib/arbor/commands/llm/disclosure_prompt.ex"
    client = "packages/arbor_llm/lib/arbor/llm/client.ex"

    neighbors = [
      "apps/arbor_commands/lib/arbor/commands/llm/disclosure_prompt_extra.ex",
      "apps/arbor_commands/lib/arbor/commands/llm/unrelated.ex",
      "apps/arbor_commands/lib/arbor/commands/llm/disclosure_prompt.exs",
      "apps/arbor_commands/test/arbor/commands/llm/disclosure_prompt.ex",
      "apps/arbor_ai/lib/arbor/ai/disclosure_prompt.ex",
      "apps/arbor_ai/lib/arbor/ai/unrelated.ex",
      "packages/arbor_commands/lib/arbor/commands/llm/disclosure_prompt.ex"
    ]

    for path <- [prompt, client] ++ neighbors, do: source!(root, path)
    git!(root, ["add", "."])
    assert {:ok, current} = PlatformInventory.run(root: root)

    assert Map.new(current["entries"], &{&1["path"], &1["app"]}) == %{
             prompt => "arbor_commands",
             client => "arbor_llm"
           }

    assert Scope.source_app(prompt) == {:ok, "arbor_commands"}
    for path <- neighbors, do: assert(match?({:error, _reason}, Scope.source_app(path)))

    client_entry = Enum.find(current["entries"], &(&1["path"] == client))

    review = [
      %{
        "path" => client,
        "blob_oid" => client_entry["blob_oid"],
        "class" => "system_extension",
        "rationale" => "Fixture review covers only the library source, not the product prompt."
      }
    ]

    review_path = Path.join(root, "reviews/library-only.json")
    File.mkdir_p!(Path.dirname(review_path))
    File.write!(review_path, Jason.encode!(review))

    assert {:ok, report} =
             PlatformInventory.run(root: root, review: "reviews/library-only.json", mode: "check")

    assert report["entries"] == current["entries"]
    assert report["status"] == "mismatch"
    assert report["counts"]["reviewed_files"] == 1
    assert report["counts"]["unreviewed_files"] == 1

    assert report["comparison"]["failures"] == [
             %{"reason" => "missing_review", "detail" => prompt}
           ]
  end

  test "security regression: former embedded LLM sources fail the public physical-owner gate" do
    root = repository!()
    source!(root, "packages/arbor_llm/lib/arbor/llm/client.ex")
    old_path = "apps/arbor_llm/lib/arbor/llm/client.ex"
    source!(root, old_path)
    git!(root, ["add", "."])

    assert {:error, {:invalid_path, ^old_path}} = PlatformInventory.run(root: root)
  end

  test "security regression: stale LLM review paths cannot qualify relocated source owners" do
    root = repository!()
    for {path, _owner} <- @family, do: source!(root, path)
    git!(root, ["add", "."])
    assert {:ok, current} = PlatformInventory.run(root: root)

    reviews =
      Enum.map(current["entries"], fn entry ->
        path = historical_path(entry["path"])

        %{
          "path" => path,
          "blob_oid" => entry["blob_oid"],
          "class" => "system_extension",
          "rationale" => "Historical source review does not qualify a relocated physical owner."
        }
      end)
      |> Enum.sort_by(& &1["path"])

    review_path = Path.join(root, "reviews/old-llm.json")
    File.mkdir_p!(Path.dirname(review_path))
    File.write!(review_path, Jason.encode!(reviews))

    assert {:ok, report} =
             PlatformInventory.run(root: root, review: "reviews/old-llm.json", mode: "check")

    assert report["status"] == "mismatch"
    assert report["counts"]["reviewed_files"] == 1
    assert report["counts"]["unreviewed_files"] == 5

    for {path, _owner} <- @family, historical_path(path) != path do
      assert %{"reason" => "extra_review", "detail" => historical_path(path)} in report[
               "comparison"
             ]["failures"]

      assert %{"reason" => "missing_review", "detail" => path} in report["comparison"]["failures"]
    end
  end

  defp historical_path("packages/arbor_llm/" <> relative), do: "apps/arbor_llm/" <> relative
  defp historical_path("apps/arbor_commands/" <> relative), do: "apps/arbor_llm/" <> relative
  defp historical_path("apps/arbor_orchestrator/" <> relative), do: "apps/arbor_llm/" <> relative
  defp historical_path(path), do: path

  defp repository! do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), "arbor-llm-platform-scope-#{suffix}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "packages/arbor_kernel/mix.exs"] do
      full = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "# private repository marker\n")
    end

    git!(root, ["init", "--quiet"])

    git!(root, [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--allow-empty",
      "--quiet",
      "-m",
      "fixture"
    ])

    root
  end

  defp source!(root, path) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "defmodule Fixture.Source do\n  def value, do: :ok\nend\n")
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
