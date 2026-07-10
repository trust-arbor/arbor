defmodule Arbor.Actions.Coding.CrossApp.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CrossApp.Core

  @moduletag :fast

  test "accepts only bounded workspace_id and optional timeout" do
    assert {:ok, input} =
             Core.new(%{
               workspace_id: "ws_opaque",
               timeout: 10_000
             })

    assert input.workspace_id == "ws_opaque"
    assert input.timeout == 10_000

    assert {:ok, %{timeout: 300_000}} = Core.new(%{workspace_id: "ws_opaque"})

    assert {:ok, %{timeout: 600_000}} =
             Core.new(%{workspace_id: "ws_opaque", timeout: "600000"})

    for invalid <- ["600001", "999", "0600000", "600000ms", " 600000"] do
      assert {:error, :invalid_timeout} =
               Core.new(%{workspace_id: "ws_opaque", timeout: invalid})
    end

    assert {:error, :unsupported_parameter} =
             Core.new(%{workspace_id: "ws_opaque", path: "/tmp/repo"})

    assert {:error, :unsupported_parameter} =
             Core.new(%{workspace_id: "ws_opaque", base_commit: "abc"})

    assert {:error, :unsupported_parameter} =
             Core.new(%{workspace_id: "ws_opaque", test_paths: ["apps/a/test"]})

    assert {:error, :invalid_workspace_id} = Core.new(%{})
  end

  test "selects directly changed apps plus every downstream in-umbrella dependent" do
    assert {:ok, graph} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "beta", app: "beta", deps: ["alpha"]},
               %{dir: "gamma", app: "gamma", deps: ["beta"]},
               %{dir: "delta", app: "delta", deps: []}
             ])

    assert {:ok, selection} =
             Core.select(["apps/alpha/lib/alpha.ex", "docs/readme.md"], graph)

    assert selection.changed_apps == ["alpha"]
    assert selection.affected_apps == ["alpha", "beta", "gamma"]
    assert selection.test_paths == ["apps/alpha/test", "apps/beta/test", "apps/gamma/test"]
    refute selection.root_wide
    assert "docs/readme.md" in selection.changed_files
  end

  test "root build-impact files select all apps; unrelated docs do not widen app-scoped change" do
    assert {:ok, graph} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "beta", app: "beta", deps: ["alpha"]},
               %{dir: "delta", app: "delta", deps: []}
             ])

    assert {:ok, root_selection} = Core.select(["mix.lock", "docs/guide.md"], graph)
    assert root_selection.root_wide
    assert root_selection.changed_apps == []
    assert root_selection.affected_apps == ["alpha", "beta", "delta"]

    assert {:ok, docs_only} = Core.select(["README.md", "docs/guide.md"], graph)
    refute docs_only.root_wide
    assert docs_only.changed_apps == []
    assert docs_only.affected_apps == []
    assert docs_only.test_paths == []

    assert {:ok, scoped} =
             Core.select(["apps/beta/lib/beta.ex", "docs/guide.md"], graph)

    assert scoped.changed_apps == ["beta"]
    # docs do not add other apps
    assert scoped.affected_apps == ["beta"]
  end

  test "fails closed for malformed or ambiguous dependency metadata" do
    assert {:error, :app_dir_name_mismatch} =
             Core.build_graph([%{dir: "alpha", app: "other", deps: []}])

    assert {:error, :duplicate_app_dir} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "alpha", app: "alpha", deps: []}
             ])

    assert {:error, {:unknown_in_umbrella_dep, _}} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: ["missing"]}
             ])

    assert {:ok, graph} =
             Core.build_graph([%{dir: "alpha", app: "alpha", deps: []}])

    assert {:error, {:changed_unknown_app, "ghost"}} =
             Core.select(["apps/ghost/lib/x.ex"], graph)
  end

  test "show assembles domain failure evidence without claiming zero cycles" do
    selection = %{
      changed_files: ["apps/alpha/lib/a.ex"],
      changed_apps: ["alpha"],
      affected_apps: ["alpha", "beta"],
      test_paths: ["apps/alpha/test", "apps/beta/test"],
      root_wide: false
    }

    compile_fail =
      Core.completed_check(%{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "error",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("a", 64),
        "stderr_sha256" => String.duplicate("b", 64)
      })

    evidence =
      Core.show(%{
        selection: selection,
        checks: %{
          compile: compile_fail,
          xref: Core.skipped_check("compile_failed"),
          test: Core.skipped_check("compile_failed")
        },
        base_commit: "abc123"
      })

    refute evidence.passed
    assert evidence.reason == "compile_failed"
    assert evidence.xref["status"] == "skipped"
    assert evidence.test["status"] == "skipped"
    assert evidence.affected_apps == ["alpha", "beta"]
    assert {:ok, _} = Jason.encode(evidence)
  end
end
