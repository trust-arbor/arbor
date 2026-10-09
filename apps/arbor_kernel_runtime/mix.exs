Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.KernelRuntime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/trust-arbor/arbor_monitor"

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    generated_elixirc_path = generated_elixirc_path(paths[:build_path], Mix.env())

    [
      app: :arbor_kernel_runtime,
      version: @version,
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env(), generated_elixirc_path),
      start_permanent: Mix.env() == :prod,
      compilers: [:arbor_safe_path_reader, :boundary] ++ Mix.compilers(),
      boundary: [
        default: [
          type: :strict,
          check: [aliases: true]
        ]
      ],
      deps: deps(),
      package: package(),
      docs: docs(),
      test_pattern: "*_test.exs",
      test_coverage: [
        threshold: 90,
        ignore_modules: [
          Mix.Tasks.Arbor.Apps,
          Mix.Tasks.Arbor.Attach,
          Mix.Tasks.Arbor.Config,
          Mix.Tasks.Arbor.Eval,
          Mix.Tasks.Arbor.Helpers,
          Mix.Tasks.Arbor.Logs,
          Mix.Tasks.Arbor.Recompile,
          Mix.Tasks.Arbor.Restart,
          Mix.Tasks.Arbor.Start,
          Mix.Tasks.Arbor.Status,
          Mix.Tasks.Arbor.Stop
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Arbor.KernelRuntime.Application, []}
    ]
  end

  defp elixirc_paths(:test, generated), do: ["lib", "test/support", generated]
  defp elixirc_paths(_env, generated), do: ["lib", generated]

  defp generated_elixirc_path(build_path, env) do
    build_path
    |> Path.join(Atom.to_string(env))
    |> Path.join("generated/arbor_kernel_runtime")
    |> Path.expand(__DIR__)
  end

  defp deps do
    [
      {:arbor_kernel, in_umbrella: true},
      # Two-segment range: req_llm >= 1.25 compiles against Finch >= 0.22
      # (Finch.Pool struct + Finch.Request :pool_tag); a three-segment
      # `~> 0.21.0` here capped resolution below that and broke req_llm.
      {:finch, "~> 0.24", runtime: false},
      {:jason, "~> 1.4"},
      # OAuth's bounded HTTP/1 pool relies on Mint's parser-level response
      # header limit and the response-smuggling fixes released in 1.9.3.
      {:mint, "~> 1.9.3", override: true, runtime: false},
      {:llm_db, "~> 2026.1", optional: true, runtime: false},
      {:req, "~> 0.5", runtime: false},
      {:zoi, "~> 0.17"},
      {:telemetry, "~> 1.0"},
      {:recon, "~> 2.5", runtime: false},
      {:boundary, "~> 0.10", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "arbor_kernel_runtime",
      files: ~w(lib c_src priv mix.exs README.md),
      licenses: ["MIT"],
      links: %{
        "GitLab" => @source_url
      },
      maintainers: ["Trust Arbor Team"]
    ]
  end

  defp docs do
    [
      main: "Arbor.Common",
      extras: ["README.md"]
    ]
  end
end

defmodule Mix.Tasks.Compile.ArborSafePathReader do
  @moduledoc false
  use Mix.Task.Compiler
  @recursive true

  @artifact_module Arbor.Common.SafePath.NativeReaderArtifact

  def source, do: Path.join(__DIR__, "c_src/arbor_safe_path_reader.c")
  def mix_project_source, do: Path.join(__DIR__, "mix.exs")

  def generated_dir do
    Path.join([Mix.Project.build_path(), "generated", "arbor_kernel_runtime"])
  end

  def native_target, do: Path.join(generated_dir(), "arbor_safe_path_reader.bin")
  def generated_source, do: Path.join(generated_dir(), "native_reader_artifact.ex")

  defp legacy_executable do
    Path.join(Mix.Project.compile_path(), "arbor_safe_path_reader")
  end

  @impl true
  def run(_args) do
    if Mix.Project.config()[:app] == :arbor_kernel_runtime do
      # Earlier revisions put the executable in ebin. It must never remain as
      # an executable runtime deputy in a workspace-owned build tree.
      _ = File.rm(legacy_executable())

      if Mix.Utils.stale?(
           [source(), mix_project_source()],
           [native_target(), generated_source()]
         ) do
        File.mkdir_p!(generated_dir())
        compile_and_embed!()
        {:ok, []}
      else
        :noop
      end
    else
      :noop
    end
  end

  @impl true
  def clean do
    if Mix.Project.config()[:app] == :arbor_kernel_runtime do
      _ = File.rm(legacy_executable())
      _ = File.rm_rf(generated_dir())
    end

    :ok
  end

  defp compile_and_embed! do
    compiler = System.find_executable("cc") || Mix.raise("C compiler not found")
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    native_temp = native_target() <> ".tmp-" <> suffix
    source_temp = generated_source() <> ".tmp-" <> suffix

    args = [
      "-std=c11",
      "-O2",
      "-Wall",
      "-Wextra",
      "-Werror",
      "-D_DARWIN_C_SOURCE",
      "-D_GNU_SOURCE",
      "-D_POSIX_C_SOURCE=200809L",
      source(),
      "-o",
      native_temp
    ]

    case System.cmd(compiler, args, stderr_to_stdout: true) do
      {output, 0} ->
        try do
          # This compiler output is data for Elixir compilation. It is never a
          # runtime executable, so leave it non-executable in the build tree.
          File.chmod!(native_temp, 0o600)
          binary = File.read!(native_temp)
          File.write!(source_temp, render_artifact_module(binary))
          File.rename!(native_temp, native_target())
          File.rename!(source_temp, generated_source())

          if output != "", do: Mix.shell().info(output)
        after
          _ = File.rm(native_temp)
          _ = File.rm(source_temp)
        end

      {output, _status} ->
        Mix.raise("failed to compile arbor_safe_path_reader:\n#{output}")
    end
  end

  defp render_artifact_module(binary) do
    module_name = inspect(@artifact_module)
    encoded = Base.encode64(binary)
    encoded_literal = inspect(encoded, limit: :infinity, printable_limit: :infinity)
    binary_sha256 = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    source_sha256 = source() |> File.read!() |> then(&:crypto.hash(:sha256, &1))
    source_sha256 = Base.encode16(source_sha256, case: :lower)

    """
    defmodule #{module_name} do
      @moduledoc false

      @binary Base.decode64!(#{encoded_literal})
      @binary_sha256 #{inspect(binary_sha256)}
      @source_sha256 #{inspect(source_sha256)}

      def binary, do: @binary
      def binary_sha256, do: @binary_sha256
      def source_sha256, do: @source_sha256
    end
    """
  end
end
