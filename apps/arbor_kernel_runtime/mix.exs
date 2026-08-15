Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.KernelRuntime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://gitlab.com/trust-arbor/arbor_monitor"

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_kernel_runtime,
      version: @version,
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
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
      extra_applications: [:logger, :os_mon],
      mod: {Arbor.KernelRuntime.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:arbor_kernel, in_umbrella: true},
      {:finch, "~> 0.21.0"},
      {:jason, "~> 1.4"},
      # OAuth's bounded HTTP/1 pool relies on Mint's parser-level response
      # header limit and the response-smuggling fixes released in 1.9.3.
      {:mint, "~> 1.9.3", override: true},
      {:req, "~> 0.5"},
      {:zoi, "~> 0.17"},
      {:telemetry, "~> 1.0"},
      {:recon, "~> 2.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      name: "arbor_kernel_runtime",
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
