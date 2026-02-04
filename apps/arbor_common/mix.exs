defmodule ArborCommon.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_common,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Common.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
