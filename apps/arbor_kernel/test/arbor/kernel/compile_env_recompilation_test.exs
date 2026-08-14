defmodule Arbor.Kernel.CompileEnvRecompilationTest do
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag timeout: 180_000

  # Nested Mix compiles of a temp project are too expensive for a root-wide
  # umbrella suite. Opt in with ARBOR_APP_ENV_PROBES=1.
  if System.get_env("ARBOR_APP_ENV_PROBES") != "1" do
    @moduletag skip: "set ARBOR_APP_ENV_PROBES=1 to run nested compile_env recompilation"
  end

  @warning_needles [
    "unavailable",
    "is not available"
  ]

  @retired_apps ["arbor_common", "arbor_signals", "arbor_monitor", "arbor_contracts"]

  test "changing :arbor_kernel nested compile_env recompiles the dependent module" do
    root = umbrella_root()
    template_dir = Path.join(root, "apps/arbor_kernel/priv/packaging/compile_env_probe")
    template_snapshot = snapshot_tree(template_dir)

    tmp =
      Path.expand(
        Path.join(
          System.tmp_dir!(),
          "arbor-compile-env-probe-#{:erlang.unique_integer([:positive])}"
        )
      )

    on_exit(fn ->
      File.rm_rf(tmp)
      assert snapshot_tree(template_dir) == template_snapshot
    end)

    kernel_abs = Path.expand("apps/arbor_kernel", root)
    write_temp_project(tmp, kernel_abs, :first)

    build_path = Path.expand(Path.join(tmp, "build"))
    deps_path = Path.expand(Path.join(tmp, "deps"))
    File.mkdir_p!(build_path)
    File.mkdir_p!(deps_path)

    env = mix_env(root, build_path, deps_path, "prod")

    first = mix!(tmp, env, ["compile", "--warnings-as-errors"])
    refute_probe_warnings(first)
    assert mix_eval!(tmp, env) == ":first"

    write_config(tmp, :second)
    second = mix!(tmp, env, ["compile", "--warnings-as-errors"])
    refute_probe_warnings(second)
    assert mix_eval!(tmp, env) == ":second"

    write_config(tmp, :missing)
    third = mix!(tmp, env, ["compile", "--warnings-as-errors"])
    refute_probe_warnings(third)
    assert mix_eval!(tmp, env) == ":missing"
  end

  defp write_temp_project(tmp, kernel_abs, value) do
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.mkdir_p!(Path.join(tmp, "config"))

    File.write!(Path.join(tmp, "mix.exs"), """
    # Probe-only fixture; not a production release.
    defmodule ArborKernelCompileEnvProbe.MixProject do
      use Mix.Project

      def project do
        [
          app: :arbor_kernel_compile_env_probe,
          version: "0.0.0",
          elixir: "~> 1.17",
          build_path: System.fetch_env!("MIX_BUILD_PATH"),
          deps_path: System.fetch_env!("MIX_DEPS_PATH"),
          deps: [{:arbor_kernel, path: #{inspect(kernel_abs)}}]
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """)

    File.write!(Path.join(tmp, "lib/arbor_kernel_compile_env_probe.ex"), """
    # Probe-only fixture; not a production release.
    defmodule ArborKernelCompileEnvProbe do
      @value Application.compile_env(:arbor_kernel, [:common, :k2e_compile_probe], :missing)
      def value, do: @value
    end
    """)

    write_config(tmp, value)
  end

  defp write_config(tmp, :missing) do
    File.write!(Path.join(tmp, "config/config.exs"), """
    # Probe-only fixture; not a production release.
    import Config

    config :arbor_kernel, common: []
    """)
  end

  defp write_config(tmp, value) do
    File.write!(Path.join(tmp, "config/config.exs"), """
    # Probe-only fixture; not a production release.
    import Config

    config :arbor_kernel, common: [k2e_compile_probe: #{inspect(value)}]
    """)
  end

  defp mix_env(root, build_path, deps_path, mix_env) do
    {:ok, erlang_root, elixir_root} = pinned_roots(root)

    [
      {"ARBOR_MIX_CONTAINED", "1"},
      {"ARBOR_ERLANG_ROOT", erlang_root},
      {"ARBOR_ELIXIR_ROOT", elixir_root},
      {"MIX_BUILD_PATH", build_path},
      {"MIX_DEPS_PATH", deps_path},
      {"MIX_ENV", mix_env}
    ]
  end

  defp mix!(tmp, env, args) do
    {output, status} =
      System.cmd(Path.join(umbrella_root(), "bin/mix"), args,
        cd: tmp,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, "mix #{Enum.join(args, " ")} failed (#{status}):\n#{output}"
    output
  end

  defp mix_eval!(tmp, env) do
    {output, status} =
      System.cmd(
        Path.join(umbrella_root(), "bin/mix"),
        [
          "run",
          "--no-start",
          "-e",
          "IO.write(\"PROBE_VALUE=\" <> inspect(ArborKernelCompileEnvProbe.value()))"
        ],
        cd: tmp,
        env: env
      )

    assert status == 0, "mix run failed (#{status}):\n#{output}"

    case Regex.run(~r/PROBE_VALUE=(\S+)/, output) do
      [_, value] -> value
      _ -> flunk("missing PROBE_VALUE in:\n#{output}")
    end
  end

  defp refute_probe_warnings(output) do
    Enum.each(@warning_needles, fn needle ->
      refute output =~ needle, "unexpected #{inspect(needle)} in:\n#{output}"
    end)

    Enum.each(@retired_apps, fn app ->
      refute String.contains?(output, ":" <> app),
             "unexpected retired app :#{app} in:\n#{output}"
    end)
  end

  defp pinned_roots(root) do
    mise = System.find_executable("mise") || Path.expand("~/.local/bin/mise")
    {erlang, 0} = System.cmd(mise, ["where", "erlang"], cd: root, stderr_to_stdout: true)
    {elixir, 0} = System.cmd(mise, ["where", "elixir"], cd: root, stderr_to_stdout: true)
    {:ok, String.trim(erlang), String.trim(elixir)}
  end

  defp snapshot_tree(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Map.new(fn path -> {Path.relative_to(path, dir), File.read!(path)} end)
  end

  defp umbrella_root do
    find_root(__DIR__)
  end

  defp find_root(dir) do
    cond do
      File.regular?(Path.join([dir, "apps", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> flunk("umbrella root not found")
      true -> find_root(Path.dirname(dir))
    end
  end
end
