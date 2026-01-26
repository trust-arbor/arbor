defmodule Arbor.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "2.0.0-dev",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    [
      # Jido ecosystem (path deps for local development)
      {:jido, path: "../jido", override: true},
      {:jido_ai, path: "../jido_ai", override: true}
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict"],
      "test.fast": ["test --only fast"]
    ]
  end
end
