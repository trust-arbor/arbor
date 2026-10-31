defmodule Arbor.Historian.MixProject do
  use Mix.Project
  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_historian,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      test_ignore_filters: [~r"^test/support/"],
      deps: deps(),
      description: "Bounded history queries, durable audit delivery and stream lifecycle",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {Arbor.Historian.Application, []}]

  defp deps do
    [
      kernel_dependency(),
      support_dependency(),
      persistence_dependency(),
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:typed_struct, "~> 0.3", runtime: false},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end

  defp kernel_dependency do
    case System.get_env("ARBOR_KERNEL_PATH") do
      nil -> {:arbor_kernel, "~> 2.0.0-dev"}
      path -> {:arbor_kernel, "~> 2.0.0-dev", path: path, override: true}
    end
  end

  defp support_dependency do
    case System.get_env("ARBOR_SUPPORT_PATH") do
      nil -> {:arbor_support, "~> 0.1.0-dev"}
      path -> {:arbor_support, "~> 0.1.0-dev", path: path, override: true}
    end
  end

  defp persistence_dependency do
    case System.get_env("ARBOR_PERSISTENCE_PATH") do
      nil -> {:arbor_persistence, "~> 0.1.0-dev"}
      path -> {:arbor_persistence, "~> 0.1.0-dev", path: path, override: true}
    end
  end
end
