defmodule Arbor.Capabilities.Signals.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_capabilities_signals,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps:
        [
          capabilities_dependency(),
          signals_dependency(),
          {:boundary, "~> 0.10", runtime: false}
        ] ++ kernel_override(),
      description:
        "Explicit Capabilities authorization, crypto and synchronization adapters for Signals",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  defp capabilities_dependency do
    case System.get_env("ARBOR_CAPABILITIES_PATH") do
      nil -> {:arbor_capabilities, "~> 0.1.0-dev", runtime: false}
      path -> {:arbor_capabilities, "~> 0.1.0-dev", path: path, override: true, runtime: false}
    end
  end

  defp signals_dependency do
    case System.get_env("ARBOR_SIGNALS_PATH") do
      nil -> {:arbor_signals, "~> 0.2.0-dev", runtime: false}
      path -> {:arbor_signals, "~> 0.2.0-dev", path: path, override: true, runtime: false}
    end
  end

  # Local Core and Signals must resolve their shared Kernel to one source.
  # Publication without the explicit override keeps only the public adapter deps.
  defp kernel_override do
    case System.get_env("ARBOR_KERNEL_PATH") do
      nil -> []
      path -> [{:arbor_kernel, "~> 2.0.0-dev", path: path, override: true, runtime: false}]
    end
  end

  def application, do: [extra_applications: [:logger]]
end
