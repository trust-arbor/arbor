defmodule Arbor.Actions.MixCompileArgvTest do
  @moduledoc """
  Pins the reviewed candidate Mix compile argv and proves a sources-only
  layout compiles a git dep plus a dependency-provided compiler when git is
  on PATH and the checkout has `.git`.
  """

  use ExUnit.Case, async: false

  alias Arbor.Actions.Mix, as: MixAction

  @moduletag :fast
  @moduletag timeout: 60_000

  test "candidate compile argv has no --no-deps-check" do
    assert MixAction.compile_argv() == ["compile"]
    assert MixAction.compile_argv(%{}) == ["compile"]
    assert MixAction.compile_argv(%{warnings_as_errors: false}) == ["compile"]

    assert MixAction.compile_argv(%{warnings_as_errors: true}) ==
             ["compile", "--warnings-as-errors"]

    refute "--no-deps-check" in MixAction.compile_argv()
    refute "--no-deps-check" in MixAction.compile_argv(%{warnings_as_errors: true})
  end

  test "cold compile loads a dependency compiler when git can read the checkout" do
    real_git = System.find_executable("git")
    assert is_binary(real_git), "git must be on PATH for Mix.SCM.Git.lock_status"

    {elixir_root, 0} = System.cmd("mise", ["where", "elixir"], stderr_to_stdout: true)
    {erlang_root, 0} = System.cmd("mise", ["where", "erlang"], stderr_to_stdout: true)
    elixir_root = String.trim(elixir_root)
    erlang_root = String.trim(erlang_root)
    mix = Path.join(elixir_root, "bin/mix")
    assert File.regular?(mix)

    root =
      Path.join(
        System.tmp_dir!(),
        "mix-git-dep-compile-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    project = Path.join(root, "project")
    stub_bin = Path.join(root, "bin")
    git_dep = Path.join(project, "deps/jido_sandbox")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(git_dep)
    File.mkdir_p!(Path.join(project, "deps/boundary/lib/mix/tasks/compile"))
    File.mkdir_p!(stub_bin)

    File.write!(Path.join(project, "mix.exs"), """
    defmodule GitDepFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :git_dep_fixture,
          version: "0.0.1",
          elixir: "~> 1.14",
          compilers: [:fixture_boundary] ++ Mix.compilers(),
          deps: deps()
        ]
      end

      defp deps do
        [
          {:boundary, path: "deps/boundary", runtime: false},
          {:jido_sandbox, git: "https://example.invalid/jido_sandbox.git"}
        ]
      end
    end
    """)

    File.write!(Path.join(project, "lib/git_dep_fixture.ex"), """
    defmodule GitDepFixture do
      def ok, do: :ok
    end
    """)

    File.write!(Path.join(git_dep, "mix.exs"), """
    defmodule JidoSandbox.MixProject do
      use Mix.Project

      def project do
        [app: :jido_sandbox, version: "0.0.1"]
      end
    end
    """)

    git_env = [
      {"GIT_AUTHOR_NAME", "Arbor Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.invalid"},
      {"GIT_COMMITTER_NAME", "Arbor Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.invalid"}
    ]

    {_, 0} =
      System.cmd(real_git, ["-c", "init.defaultBranch=main", "init", "--quiet"], cd: git_dep)

    {_, 0} = System.cmd(real_git, ["add", "mix.exs"], cd: git_dep, env: git_env)

    {_, 0} =
      System.cmd(real_git, ["commit", "--quiet", "-m", "init"], cd: git_dep, env: git_env)

    {_, 0} =
      System.cmd(
        real_git,
        ["remote", "add", "origin", "https://example.invalid/jido_sandbox.git"],
        cd: git_dep
      )

    {rev, 0} = System.cmd(real_git, ["rev-parse", "HEAD"], cd: git_dep)
    rev = String.trim(rev)

    File.write!(Path.join(project, "mix.lock"), """
    %{
      "jido_sandbox": {:git, "https://example.invalid/jido_sandbox.git", "#{rev}", []},
    }
    """)

    File.write!(Path.join(project, "deps/boundary/mix.exs"), """
    defmodule BoundaryFixture.MixProject do
      use Mix.Project

      def project do
        [app: :boundary, version: "0.0.1"]
      end
    end
    """)

    File.write!(
      Path.join(project, "deps/boundary/lib/mix/tasks/compile/fixture_boundary.ex"),
      """
      defmodule Mix.Tasks.Compile.FixtureBoundary do
        use Mix.Task.Compiler

        @impl true
        def run(_args) do
          File.write!("fixture_boundary_ran", "ok")
          {:ok, []}
        end
      end
      """
    )

    git_log = Path.join(root, "git-invoked.log")
    git_wrapper = Path.join(stub_bin, "git")

    File.write!(git_wrapper, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{git_log}"
    exec "#{real_git}" "$@"
    """)

    File.chmod!(git_wrapper, 0o755)

    path =
      Enum.join(
        [
          stub_bin,
          Path.join(erlang_root, "bin"),
          Path.join(elixir_root, "bin"),
          System.get_env("PATH", "/usr/bin:/bin")
        ],
        ":"
      )

    env =
      System.get_env()
      |> Map.put("PATH", path)
      |> Map.put("MIX_ENV", "dev")
      |> Map.put("MIX_BUILD_PATH", Path.join(root, "build"))
      # nil removes inherited keys; Map.delete leaves the test-process value.
      |> Map.put("MIX_DEPS_PATH", nil)
      |> Map.put("MIX_EXS", nil)

    task =
      Task.async(fn ->
        System.cmd(mix, MixAction.compile_argv(),
          cd: project,
          env: env,
          stderr_to_stdout: true
        )
      end)

    assert {:ok, {output, status}} = Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill)
    assert status == 0, output
    refute output =~ "could not be found"
    assert File.read!(Path.join(project, "fixture_boundary_ran")) == "ok"
    assert File.exists?(git_log)
    git_invocations = File.read!(git_log)
    assert git_invocations =~ "rev-parse"
  end

  test "cold compile uses a pre-fetched dep artifact and does not download" do
    {elixir_root, 0} = System.cmd("mise", ["where", "elixir"], stderr_to_stdout: true)
    {erlang_root, 0} = System.cmd("mise", ["where", "erlang"], stderr_to_stdout: true)
    elixir_root = String.trim(elixir_root)
    erlang_root = String.trim(erlang_root)
    mix = Path.join(elixir_root, "bin/mix")
    assert File.regular?(mix)

    root =
      Path.join(
        System.tmp_dir!(),
        "mix-prefetch-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    project = Path.join(root, "project")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "deps/payload/lib/mix/tasks/compile"))
    File.mkdir_p!(Path.join(project, "deps/payload/priv/0.1.5"))

    File.write!(Path.join(project, "mix.exs"), """
    defmodule PrefetchFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :prefetch_fixture,
          version: "0.0.1",
          elixir: "~> 1.14",
          compilers: [:download_payload] ++ Mix.compilers(),
          deps: [{:payload, path: "deps/payload", runtime: false}]
        ]
      end
    end
    """)

    File.write!(Path.join(project, "lib/prefetch_fixture.ex"), """
    defmodule PrefetchFixture do
      def ok, do: :ok
    end
    """)

    File.write!(Path.join(project, "deps/payload/mix.exs"), """
    defmodule Payload.MixProject do
      use Mix.Project

      def project do
        [app: :payload, version: "0.0.1"]
      end
    end
    """)

    File.write!(
      Path.join(project, "deps/payload/lib/mix/tasks/compile/download_payload.ex"),
      """
      defmodule Mix.Tasks.Compile.DownloadPayload do
        use Mix.Task.Compiler

        @impl true
        def run(_args) do
          artifact = Path.join([File.cwd!(), "deps/payload/priv/0.1.5/vec0.so"])

          if File.exists?(artifact) do
            File.write!("download_payload_ran", "skip")
            {:ok, []}
          else
            Mix.raise("would download under network none")
          end
        end
      end
      """
    )

    File.write!(Path.join(project, "deps/payload/priv/0.1.5/vec0.so"), "native\n")

    path =
      Enum.join(
        [
          Path.join(erlang_root, "bin"),
          Path.join(elixir_root, "bin"),
          System.get_env("PATH", "/usr/bin:/bin")
        ],
        ":"
      )

    env =
      System.get_env()
      |> Map.put("PATH", path)
      |> Map.put("MIX_ENV", "dev")
      |> Map.put("MIX_BUILD_PATH", Path.join(root, "build"))
      |> Map.put("MIX_DEPS_PATH", nil)
      |> Map.put("MIX_EXS", nil)

    task =
      Task.async(fn ->
        System.cmd(mix, MixAction.compile_argv(),
          cd: project,
          env: env,
          stderr_to_stdout: true
        )
      end)

    assert {:ok, {output, status}} = Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill)
    assert status == 0, output
    refute output =~ "would download"
    assert File.read!(Path.join(project, "download_payload_ran")) == "skip"
  end
end
