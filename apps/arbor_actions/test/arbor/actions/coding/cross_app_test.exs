defmodule Arbor.Actions.Coding.CrossAppTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CrossApp.Validate
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :slow

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  test "discovery, name resolution, and canonical URI" do
    assert Validate in Actions.list_actions().coding
    assert Validate.name() == "coding_cross_app_validate"
    assert {:ok, Validate} = Actions.name_to_module("coding_cross_app_validate")
    assert {:ok, Validate} = Actions.name_to_module("coding.cross_app.validate")

    assert Actions.canonical_uri_for(Validate, %{}) ==
             "arbor://action/coding/cross_app/validate"
  end

  test "enforces lease authority: opaque workspace_id alone is not enough", %{tmp_dir: tmp_dir} do
    fixture = leased_umbrella(tmp_dir)
    workspace_id = fixture.lease.workspace_id
    parent = self()

    # A foreign process with only the opaque id (no owner pid, no matching
    # task_id+principal) must not resolve the live workspace.
    foreign =
      spawn(fn ->
        result = Validate.run(%{workspace_id: workspace_id}, %{})
        send(parent, {:foreign_result, result})
      end)

    ref = Process.monitor(foreign)

    assert_receive {:foreign_result, {:error, reason}}, 5_000

    assert reason in [
             :workspace_unauthorized,
             :unauthorized,
             :not_authorized,
             :workspace_not_found
           ]

    assert_receive {:DOWN, ^ref, :process, ^foreign, _}, 1_000

    # Owner-process callers with a mismatched task_id still resolve via owner
    # pid; a non-owner process with wrong task+principal must not.
    foreign_task =
      spawn(fn ->
        result =
          Validate.run(
            %{workspace_id: workspace_id},
            %{task_id: "wrong-task", agent_id: "wrong-agent"}
          )

        send(parent, {:foreign_task_result, result})
      end)

    ref2 = Process.monitor(foreign_task)
    assert_receive {:foreign_task_result, {:error, wrong_task_reason}}, 5_000

    assert wrong_task_reason in [
             :workspace_unauthorized,
             :unauthorized,
             :not_authorized,
             :workspace_not_found
           ]

    assert_receive {:DOWN, ^ref2, :process, ^foreign_task, _}, 1_000

    assert {:error, :unsupported_parameter} =
             Validate.run(
               %{
                 workspace_id: workspace_id,
                 path: fixture.lease.worktree_path
               },
               fixture.context
             )

    assert {:error, :unsupported_parameter} =
             Validate.run(
               %{
                 workspace_id: workspace_id,
                 base_commit: fixture.lease.base_commit
               },
               fixture.context
             )
  end

  @tag :requires_pinned_mix
  test "selects downstream app tests for a two-app fixture and returns bounded evidence", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_umbrella(tmp_dir)

    # Change only alpha (behavior-preserving) — beta depends on alpha so both
    # apps' tests should be selected and still pass.
    alpha_lib = Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex")

    File.write!(alpha_lib, """
    defmodule Alpha do
      @moduledoc "alpha"
      def value, do: 1
      def tag, do: :alpha
    end
    """)

    assert {:ok, result} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    assert result.passed
    assert result.reason == "cross_app_validated"
    assert "apps/alpha/lib/alpha.ex" in result.changed_files
    assert result.changed_apps == ["alpha"]
    assert result.affected_apps == ["alpha", "beta"]
    assert result.test_paths == ["apps/alpha/test", "apps/beta/test"]
    assert result.compile["passed"]
    assert result.xref["passed"]
    assert result.test["passed"]
    assert is_binary(result.feedback_json)
    assert Jason.decode!(result.feedback_json)["passed"] == true
    # Does not claim zero-cycle validation.
    refute Map.has_key?(result, :cycles)
    refute Map.has_key?(result, "cycles")
  end

  @tag :requires_pinned_mix
  test "compile failure skips xref and tests and returns passed false", %{tmp_dir: tmp_dir} do
    fixture = leased_umbrella(tmp_dir)

    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex"), """
    defmodule Alpha do
      def broken, do: %{}
    end
    """)

    # Introduce a compile error
    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/broken.ex"), """
    defmodule Alpha.Broken do
      def oops, do: NoSuchModule.nowhere()
    end
    """)

    # Actually use syntax error for reliable compile fail:
    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/broken.ex"), """
    defmodule Alpha.Broken do
      def oops do
    end
    """)

    assert {:ok, result} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    refute result.passed
    assert result.reason == "compile_failed"
    refute result.compile["passed"]
    assert result.xref["status"] == "skipped"
    assert result.test["status"] == "skipped"
    assert result.xref["reason"] == "compile_failed"
  end

  @tag :requires_pinned_mix
  test "test failure returns passed false after compile and xref", %{tmp_dir: tmp_dir} do
    fixture = leased_umbrella(tmp_dir)

    File.write!(Path.join(fixture.lease.worktree_path, "apps/alpha/lib/alpha.ex"), """
    defmodule Alpha do
      def value, do: 99
    end
    """)

    assert {:ok, result} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    refute result.passed
    assert result.compile["passed"]
    assert result.xref["passed"]
    refute result.test["passed"]
    assert result.reason == "tests_failed"
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp leased_umbrella(tmp_dir) do
    repo =
      create_umbrella(Path.join(tmp_dir, "umbrella-#{System.unique_integer([:positive])}"))

    task_id = "task_cross_app_#{System.unique_integer([:positive])}"
    principal_id = "agent_cross_app_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/cross-app-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn -> _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context) end)
    %{repo: repo, lease: lease, context: context}
  end

  defp create_umbrella(path) do
    create_git_repo(path)

    File.write!(Path.join(path, "mix.exs"), """
    defmodule CrossAppFixture.MixProject do
      use Mix.Project

      def project do
        [
          apps_path: "apps",
          version: "0.1.0",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end
    end
    """)

    File.mkdir_p!(Path.join(path, "config"))
    File.write!(Path.join(path, "config/config.exs"), "import Config\n")

    write_app(path, "alpha", [], """
    defmodule Alpha do
      def value, do: 1
    end
    """)

    write_app(path, "beta", ["alpha"], """
    defmodule Beta do
      def value, do: Alpha.value()
    end
    """)

    File.write!(Path.join(path, "apps/alpha/test/alpha_test.exs"), """
    defmodule AlphaTest do
      use ExUnit.Case
      test "value", do: assert Alpha.value() == 1
    end
    """)

    File.write!(Path.join(path, "apps/beta/test/beta_test.exs"), """
    defmodule BetaTest do
      use ExUnit.Case
      test "uses alpha", do: assert Beta.value() == 1
    end
    """)

    # Provide a local mix wrapper like the real repo so run_mix prefers it.
    File.mkdir_p!(Path.join(path, "bin"))

    File.write!(Path.join(path, "bin/mix"), """
    #!/usr/bin/env bash
    exec mix "$@"
    """)

    File.chmod!(Path.join(path, "bin/mix"), 0o755)

    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "umbrella base"])
    path
  end

  defp write_app(root, name, umbrella_deps, lib_source) do
    app_root = Path.join(root, "apps/#{name}")
    File.mkdir_p!(Path.join(app_root, "lib"))
    File.mkdir_p!(Path.join(app_root, "test"))

    deps =
      umbrella_deps
      |> Enum.map(fn dep -> "      {:#{dep}, in_umbrella: true}" end)
      |> Enum.join(",\n")

    deps_block =
      if deps == "" do
        "  defp deps, do: []"
      else
        """
          defp deps do
            [
        #{deps}
            ]
          end
        """
      end

    File.write!(Path.join(app_root, "mix.exs"), """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{name},
          version: "0.1.0",
          build_path: "../../_build",
          config_path: "../../config/config.exs",
          deps_path: "../../deps",
          lockfile: "../../mix.lock",
          elixir: "~> 1.14",
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end

    #{deps_block}
    end
    """)

    File.write!(Path.join(app_root, "lib/#{name}.ex"), lib_source)
    File.write!(Path.join(app_root, "test/test_helper.exs"), "ExUnit.start()\n")
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
