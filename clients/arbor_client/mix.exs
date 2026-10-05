defmodule Arbor.Client.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_client,
      version: "0.1.0-dev",
      description: "Standalone authenticated Arbor Gateway transport and signing client",
      elixir: "~> 1.19",
      deps: deps(),
      package: [licenses: ["MIT"], files: ["lib", "mix.exs", "README.md", "LICENSE"]]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :ssl]]
  defp deps, do: [{:mint, "~> 1.0"}, {:mint_web_socket, "~> 1.0"}, {:jason, "~> 1.4"}]
end
