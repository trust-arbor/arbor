defmodule Arbor.Trust.MixProject do
  use Mix.Project
  @source_url "https://github.com/trust-arbor/arbor"
  def project do
    [
      app: :arbor_trust,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r"^test/support/"],
      deps: deps(),
      description:
        "Granular trust policy, acknowledged profiles and supervised capability grant ownership",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {Arbor.Trust.Application, []}]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      kernel_dependency(),
      capabilities_dependency(),
      support_dependency(),
      persistence_dependency(),
      {:phoenix_pubsub, "~> 2.1", optional: true, runtime: false},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:boundary, "~> 0.10", runtime: false},
      {:stream_data, "~> 1.0", only: :test, runtime: false}
    ]
  end

  defp kernel_dependency do
    case System.get_env("ARBOR_KERNEL_PATH") do
      nil -> {:arbor_kernel, "~> 2.0.0-dev"}
      path -> {:arbor_kernel, "~> 2.0.0-dev", path: path, override: true}
    end
  end

  defp capabilities_dependency do
    case System.get_env("ARBOR_CAPABILITIES_PATH") do
      nil ->
        {:arbor_capabilities, "~> 0.1.0-dev", env: Mix.env(), runtime: false}

      path ->
        {:arbor_capabilities, "~> 0.1.0-dev",
         path: path, override: true, env: Mix.env(), runtime: false}
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
      nil ->
        {:arbor_persistence, "~> 0.1.0-dev", runtime: false}

      path ->
        {:arbor_persistence, "~> 0.1.0-dev", path: path, override: true, runtime: false}
    end
  end
end
