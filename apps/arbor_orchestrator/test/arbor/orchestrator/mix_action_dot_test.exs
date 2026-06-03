defmodule Arbor.Orchestrator.MixActionDotTest do
  @moduledoc """
  End-to-end exercise: a DOT pipeline that runs the `mix_test` Action
  against a tiny generated mix project, then routes on `passed`.

  Verifies the full chain: ActionRegistry registration → ExecHandler
  resolves `action="mix_test"` → action executes against the workdir
  → return values flow into `context.exec.<node_id>.<key>` → diamond
  gate evaluates the boolean → conditional edges route correctly.

  Slow because each test spins up `mix test` in a freshly-created
  tiny project (~3 s warmup per invocation). Tagged `:slow` to keep
  the fast-test loop fast.
  """

  use ExUnit.Case, async: false
  @moduletag :slow

  setup_all do
    # Umbrella test config sets `arbor_shell, start_children: false` so the
    # ExecutionRegistry won't come up via Application start. Start it
    # directly for the duration of this test module so the Mix Action's
    # Shell.execute calls have a registry to register against.
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _pid} = Arbor.Shell.ExecutionRegistry.start_link([])
        :ok

      _pid ->
        :ok
    end

    :ok
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_mix_dot_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    project_path = Path.join(tmp_dir, "tiny_project")
    create_tiny_mix_project(project_path)

    logs_root = Path.join(tmp_dir, "logs")

    # Grant the test principal the shell:exec:mix:test capability so
    # authorize_and_execute lets mix_test through. URIs are per-
    # subcommand — use `arbor://shell/exec/mix/**` for broader grants
    # but per-test we only need the precise URI.
    # Principal IDs must use the agent_<id> convention — CapabilityStore
    # rejects bare "system".
    grant_capability("agent_test_mix", "arbor://shell/exec/mix/test")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir, project_path: project_path, logs_root: logs_root}
  end

  defp grant_capability(principal_id, resource_uri) do
    {:ok, cap} =
      Arbor.Contracts.Security.Capability.new(
        resource_uri: resource_uri,
        principal_id: principal_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    Arbor.Security.CapabilityStore.put(cap)
    :ok
  end

  test "passing test routes through mark_pass branch",
       %{project_path: project_path, logs_root: logs_root} do
    dot = build_dot(project_path)

    assert {:ok, result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)

    assert "run_test" in result.completed_nodes
    assert "mark_pass" in result.completed_nodes
    refute "mark_fail" in result.completed_nodes
    assert "done" in result.completed_nodes
  end

  test "failing test routes through mark_fail branch",
       %{project_path: project_path, logs_root: logs_root} do
    add_failing_test(project_path)

    dot = build_dot(project_path)

    assert {:ok, result} = Arbor.Orchestrator.run(dot, logs_root: logs_root)

    assert "run_test" in result.completed_nodes
    assert "mark_fail" in result.completed_nodes
    refute "mark_pass" in result.completed_nodes
    assert "done" in result.completed_nodes
  end

  # ── Pipeline shape ────────────────────────────────────────────────

  # One terminal node, two transform branches converging on it.
  # The branches act as route markers so the test can assert which
  # path the gate took.
  defp build_dot(project_path) do
    """
    digraph TestRun {
      graph [goal="Run mix_test and route on the passed boolean"]

      start [shape=Mdiamond]

      run_test [
        type="exec",
        target="action",
        action="mix_test",
        agent_id="agent_test_mix",
        param.path="#{project_path}"
      ]

      check [
        type="gate",
        shape=diamond,
        predicate="expression",
        expression="exec.run_test.passed"
      ]

      mark_pass [
        type="transform",
        prompt="Set route=pass."
      ]

      mark_fail [
        type="transform",
        prompt="Set route=fail."
      ]

      done [shape=Msquare]

      start -> run_test -> check
      check -> mark_pass [condition="context.exec.run_test.passed=true"]
      check -> mark_fail [condition="context.exec.run_test.passed!=true"]
      mark_pass -> done
      mark_fail -> done
    }
    """
  end

  # ── Tiny project helpers (copied from mix_test.exs) ───────────────

  defp create_tiny_mix_project(path) do
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project

      def project do
        [app: :tiny, version: "0.0.1", elixir: "~> 1.14"]
      end
    end
    """)

    File.write!(Path.join([path, "lib", "tiny.ex"]), """
    defmodule Tiny do
      def hi, do: :hi
    end
    """)

    File.write!(Path.join([path, "test", "test_helper.exs"]), "ExUnit.start()\n")

    File.write!(Path.join([path, "test", "tiny_test.exs"]), """
    defmodule TinyTest do
      use ExUnit.Case

      test "hi returns :hi" do
        assert Tiny.hi() == :hi
      end
    end
    """)

    File.write!(Path.join(path, ".formatter.exs"), """
    [inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"]]
    """)
  end

  defp add_failing_test(path) do
    File.write!(Path.join([path, "test", "failing_test.exs"]), """
    defmodule FailingTest do
      use ExUnit.Case

      test "this fails" do
        assert 1 == 2
      end
    end
    """)
  end
end
