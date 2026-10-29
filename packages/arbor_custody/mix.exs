defmodule Arbor.Custody.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_custody,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [],
      description: "Caller-owned custody and exact supervised-process provenance for OTP",
      package: [licenses: ["MIT"], links: %{}, files: ~w(lib mix.exs README.md LICENSE)]
    ]
  end

  # Resource lifetimes belong to callers. Starting the package creates no custody resources.
  def application, do: [extra_applications: [:crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
