Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.LLM.Host.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_llm_host,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: paths[:build_path],
      deps_path: paths[:deps_path],
      config_path: "../../config/config.exs",
      lockfile: "../../mix.lock",
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: [
        {:arbor_kernel_runtime, in_umbrella: true},
        {:arbor_llm, "~> 0.1.0", path: "../../packages/arbor_llm", env: Mix.env()},
        {:boundary, "~> 0.10", runtime: false}
      ]
    ]
  end

  # The canonical library owns its OAuth tree. This host owns no second tree.
  def application, do: [extra_applications: [:logger]]
end
