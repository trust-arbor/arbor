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

  test "next_test_step drives sequential one-path runs under a shared budget" do
    assert :complete = Core.next_test_step(10_000, [])

    assert {:run, "apps/alpha/test", 5_000, ["apps/beta/test"]} =
             Core.next_test_step(5_000, ["apps/alpha/test", "apps/beta/test"])

    assert {:timeout, "apps/beta/test", ["apps/gamma/test"]} =
             Core.next_test_step(0, ["apps/beta/test", "apps/gamma/test"])

    assert {:timeout, "apps/alpha/test", []} =
             Core.next_test_step(-3, ["apps/alpha/test"])
  end

  test "classify_app_test_result preserves tests_failed vs tests_timed_out" do
    pass =
      Core.classify_app_test_result("apps/alpha/test", %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => "ok",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("1", 64),
        "stderr_sha256" => String.duplicate("2", 64)
      })

    assert pass.passed
    assert pass.reason == nil
    refute pass.timed_out

    fail =
      Core.classify_app_test_result("apps/beta/test", %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "1 failure",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("3", 64),
        "stderr_sha256" => String.duplicate("4", 64)
      })

    refute fail.passed
    assert fail.reason == "tests_failed"

    timed =
      Core.classify_app_test_result(
        "apps/gamma/test",
        %{
          "exit_code" => 137,
          "passed" => false,
          "stdout_excerpt" => "partial",
          "stderr_excerpt" => "",
          "stdout_truncated" => false,
          "stderr_truncated" => false,
          "stdout_sha256" => String.duplicate("5", 64),
          "stderr_sha256" => String.duplicate("6", 64)
        },
        timed_out: true
      )

    refute timed.passed
    assert timed.timed_out
    assert timed.reason == "tests_timed_out"
  end

  test "exact timeout shape vs text-only timeout stays ordinary failure" do
    # Text containing "timeout" must NOT be treated as a stage/process timeout.
    text_only =
      Core.classify_app_test_result("apps/alpha/test", %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "error: connection timeout waiting for lock",
        "stderr_excerpt" => "timeout in fixture setup",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("7", 64),
        "stderr_sha256" => String.duplicate("8", 64)
      })

    refute text_only.passed
    refute text_only.timed_out
    assert text_only.reason == "tests_failed"

    assert Core.runner_timed_out?(%{
             exit_code: 1,
             stdout: "timeout",
             stderr: "timeout",
             timed_out: false
           }) == false

    assert Core.runner_timed_out?(%{exit_code: 137, timed_out: true}) == true
    assert Core.runner_timed_out?(%{"timed_out" => true, "exit_code" => 1}) == true
    assert Core.runner_timed_out?(%{reason: "timeout"}) == false
    assert Core.runner_timed_out?("timeout") == false

    assert Core.child_timed_out?(false, 1) == false
    assert Core.child_timed_out?(false, 0) == true
    assert Core.child_timed_out?(false, -5) == true
    assert Core.child_timed_out?(true, 100) == true
  end

  test "feedback_from_result hashes raw bytes and produces JSON-safe byte-bounded excerpts" do
    invalid = "hello" <> <<0xFF, 0xFE>> <> "world"
    expected_hash = :crypto.hash(:sha256, invalid) |> Base.encode16(case: :lower)

    feedback =
      Core.feedback_from_result(%{
        exit_code: 0,
        stdout: invalid,
        stderr: ""
      })

    assert feedback["passed"]
    assert feedback["stdout_sha256"] == expected_hash
    assert String.valid?(feedback["stdout_excerpt"])
    assert String.contains?(feedback["stdout_excerpt"], "hello")
    assert String.contains?(feedback["stdout_excerpt"], "world")
    # Invalid bytes replaced; raw hash still deterministic over the original binary.
    refute String.contains?(feedback["stdout_excerpt"], <<0xFF>>)
    assert {:ok, _} = Jason.encode(feedback)
    assert {:ok, _} = Jason.encode!(feedback) |> Jason.decode()

    # Multibyte: bound by bytes without splitting UTF-8 codepoints (é is 2 bytes).
    multibyte = String.duplicate("é", 1_500)
    assert byte_size(multibyte) == 3_000

    {excerpt, truncated} = Core.bound_output_excerpt(multibyte)
    assert truncated
    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= Core.max_output_excerpt_bytes()
    assert String.contains?(excerpt, "...[omitted]...")
    # Every remaining codepoint must be complete "é" or the ASCII marker.
    without_marker = String.replace(excerpt, "\n...[omitted]...\n", "")
    assert String.valid?(without_marker)
    assert rem(byte_size(without_marker), 2) == 0
    assert without_marker == String.duplicate("é", div(byte_size(without_marker), 2))
  end

  test "aggregate_test_check bounds excerpts, hashes paths+process digests, and keeps reasons stable" do
    alpha =
      Core.classify_app_test_result("apps/alpha/test", %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => "alpha-ok",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("a", 64),
        "stderr_sha256" => String.duplicate("b", 64)
      })

    beta =
      Core.classify_app_test_result("apps/beta/test", %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "beta-fail",
        "stderr_excerpt" => "err",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("c", 64),
        "stderr_sha256" => String.duplicate("d", 64)
      })

    aggregated = Core.aggregate_test_check([alpha, beta])

    refute aggregated["passed"]
    assert aggregated["reason"] == "tests_failed"
    assert aggregated["exit_code"] == 1
    assert aggregated["status"] == "completed"
    assert String.contains?(aggregated["stdout_excerpt"], "[apps/alpha/test]")
    assert String.contains?(aggregated["stdout_excerpt"], "[apps/beta/test]")
    assert String.contains?(aggregated["stdout_excerpt"], "beta-fail")
    assert byte_size(aggregated["stdout_excerpt"]) <= Core.max_aggregate_excerpt()
    refute aggregated["stdout_truncated"]

    expected_stdout_hash =
      :crypto.hash(
        :sha256,
        "apps/alpha/test\n" <>
          String.duplicate("a", 64) <>
          "\n" <>
          "apps/beta/test\n" <> String.duplicate("c", 64)
      )
      |> Base.encode16(case: :lower)

    assert aggregated["stdout_sha256"] == expected_stdout_hash

    expected_stderr_hash =
      :crypto.hash(
        :sha256,
        "apps/alpha/test\n" <>
          String.duplicate("b", 64) <>
          "\n" <>
          "apps/beta/test\n" <> String.duplicate("d", 64)
      )
      |> Base.encode16(case: :lower)

    assert aggregated["stderr_sha256"] == expected_stderr_hash

    # Deterministic: same inputs → same aggregate
    assert Core.aggregate_test_check([alpha, beta]) == aggregated

    # Over-budget combined excerpts are re-bounded independent of app count;
    # per-process hashes still cover every completed path.
    huge_alpha = %{alpha | stdout_excerpt: String.duplicate("A", 1_500), stdout_truncated: true}
    huge_beta = %{beta | stdout_excerpt: String.duplicate("B", 1_500)}
    truncated = Core.aggregate_test_check([huge_alpha, huge_beta])
    assert byte_size(truncated["stdout_excerpt"]) <= Core.max_aggregate_excerpt()
    assert truncated["stdout_truncated"] == true
    assert truncated["stdout_sha256"] == expected_stdout_hash
    assert String.contains?(truncated["stdout_excerpt"], "...[omitted]...")
    assert String.valid?(truncated["stdout_excerpt"])
    assert {:ok, _} = Jason.encode(truncated)

    exhausted = Core.budget_exhausted_result("apps/gamma/test")
    timed_out = Core.aggregate_test_check([alpha, exhausted])
    refute timed_out["passed"]
    assert timed_out["reason"] == "tests_timed_out"
    assert String.contains?(timed_out["stdout_excerpt"], "apps/gamma/test")
    assert String.contains?(timed_out["stdout_excerpt"], "budget exhausted")
    # Earlier successful evidence preserved.
    assert String.contains?(timed_out["stdout_excerpt"], "alpha-ok")

    all_pass = Core.aggregate_test_check([alpha])
    assert all_pass["passed"]
    assert all_pass["reason"] == nil
    assert all_pass["exit_code"] == 0

    assert Core.aggregate_test_check([])["reason"] == "no_existing_test_dirs"
    assert Core.aggregate_test_check([])["passed"]
  end

  test "downstream selection is unchanged by per-app test aggregation helpers" do
    assert {:ok, graph} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "beta", app: "beta", deps: ["alpha"]},
               %{dir: "gamma", app: "gamma", deps: ["beta"]}
             ])

    assert {:ok, selection} = Core.select(["apps/alpha/lib/alpha.ex"], graph)
    assert selection.affected_apps == ["alpha", "beta", "gamma"]
    assert selection.test_paths == ["apps/alpha/test", "apps/beta/test", "apps/gamma/test"]
  end
end
