defmodule Arbor.Actions.MixCompileArgvTest do
  @moduledoc """
  Pins the reviewed Mix compile argv and proves `--no-deps-check` lets a
  git-dep lock compile when `git` is absent from PATH.
  """

  use ExUnit.Case, async: false

  alias Arbor.Actions.Mix, as: MixAction

  @moduletag :fast
  @moduletag timeout: 30_000

  test "compile argv always includes --no-deps-check" do
    assert MixAction.compile_argv() == ["compile", "--no-deps-check"]
    assert MixAction.compile_argv(%{}) == ["compile", "--no-deps-check"]

    assert MixAction.compile_argv(%{warnings_as_errors: false}) ==
             ["compile", "--no-deps-check"]

    assert MixAction.compile_argv(%{warnings_as_errors: true}) ==
             ["compile", "--no-deps-check", "--warnings-as-errors"]
  end

  test "a mix.lock git dep compiles without git when --no-deps-check is set" do
    {elixir_root, 0} = System.cmd("mise", ["where", "elixir"], stderr_to_stdout: true)
    {erlang_root, 0} = System.cmd("mise", ["where", "erlang"], stderr_to_stdout: true)
    elixir_root = String.trim(elixir_root)
    erlang_root = String.trim(erlang_root)
    mix = Path.join(elixir_root, "bin/mix")
    assert File.regular?(mix)

    root =
      Path.join(
        System.tmp_dir!(),
        "mix-no-deps-check-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    project = Path.join(root, "project")
    stub_bin = Path.join(root, "bin")
    File.mkdir_p!(Path.join(project, "lib"))
    File.mkdir_p!(Path.join(project, "deps/jido_sandbox"))
    File.mkdir_p!(stub_bin)

    File.write!(Path.join(project, "mix.exs"), """
    defmodule GitDepFixture.MixProject do
      use Mix.Project

      def project do
        [app: :git_dep_fixture, version: "0.0.1", elixir: "~> 1.14", deps: deps()]
      end

      defp deps do
        [{:jido_sandbox, git: "https://example.invalid/jido_sandbox.git"}]
      end
    end
    """)

    File.write!(Path.join(project, "mix.lock"), """
    %{
      "jido_sandbox": {:git, "https://example.invalid/jido_sandbox.git", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", []},
    }
    """)

    File.write!(Path.join(project, "lib/git_dep_fixture.ex"), """
    defmodule GitDepFixture do
      def ok, do: :ok
    end
    """)

    File.write!(Path.join(project, "deps/jido_sandbox/mix.exs"), """
    defmodule JidoSandbox.MixProject do
      use Mix.Project

      def project do
        [app: :jido_sandbox, version: "0.0.1"]
      end
    end
    """)

    git_stub = Path.join(stub_bin, "git")
    git_marker = Path.join(root, "git-invoked")

    File.write!(git_stub, """
    #!/bin/sh
    echo invoked > "#{git_marker}"
    echo "git must not be invoked for digest-pinned compile" >&2
    exit 127
    """)

    File.chmod!(git_stub, 0o755)

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
      |> Map.delete("MIX_DEPS_PATH")
      |> Map.delete("MIX_EXS")

    task =
      Task.async(fn ->
        System.cmd(mix, MixAction.compile_argv(),
          cd: project,
          env: env,
          stderr_to_stdout: true
        )
      end)

    assert {:ok, {output, status}} = Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill)
    assert status == 0, output
    refute File.exists?(git_marker)
    refute output =~ "git must not be invoked"
  end
end
