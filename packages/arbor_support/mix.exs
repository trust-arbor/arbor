defmodule Arbor.Support.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_support,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:arbor_safe_path_reader, :boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: [{:boundary, "~> 0.10", runtime: false}],
      description:
        "Filesystem safety, atom conversion, redaction and pagination cursors for Elixir",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib c_src mix.exs README.md LICENSE)
      ]
    ]
  end

  # Loading the library starts no application-owned process or filesystem helper.
  def application, do: [extra_applications: [:crypto]]
end

defmodule Mix.Tasks.Compile.ArborSafePathReader do
  @moduledoc false
  use Mix.Task.Compiler
  @recursive true

  @artifact_module Arbor.Common.SafePath.NativeReaderArtifact

  def source, do: Path.join(__DIR__, "c_src/arbor_safe_path_reader.c")
  def mix_project_source, do: Path.join(__DIR__, "mix.exs")

  def generated_dir do
    Path.join([Mix.Project.build_path(), "generated", "arbor_support"])
  end

  def native_target, do: Path.join(generated_dir(), "arbor_safe_path_reader.bin")
  def generated_source, do: Path.join(generated_dir(), "native_reader_artifact.ex")

  defp legacy_executable do
    Path.join(Mix.Project.compile_path(), "arbor_safe_path_reader")
  end

  @impl true
  def run(_args) do
    if Mix.Project.config()[:app] == :arbor_support do
      register_generated_source()

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
    if Mix.Project.config()[:app] == :arbor_support do
      _ = File.rm(legacy_executable())
      _ = File.rm_rf(generated_dir())
    end

    :ok
  end

  defp register_generated_source do
    # Dependency deps_build_path overrides are installed after project/0.
    # Register against the final Mix build path, before Boundary/Elixir compile.
    # This pinned Mix internal is build-only; runtime code never loads Mix.
    paths = Mix.Project.config()[:elixirc_paths] || ["lib"]
    Mix.ProjectStack.merge_config(elixirc_paths: Enum.uniq(paths ++ [generated_dir()]))
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
