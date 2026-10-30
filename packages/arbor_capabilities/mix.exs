defmodule Arbor.Capabilities.MixProject do
  use Mix.Project

  @source_url "https://github.com/trust-arbor/arbor"

  def project do
    [
      app: :arbor_capabilities,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r"^test/support/"],
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      deps: deps(),
      description:
        "Capability authorization, cryptographic identity and caller-owned authority for OTP",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Arbor.Security.Application, []}
    ]
  end

  defp deps do
    [
      kernel_dependency(),
      custody_dependency(),
      support_dependency(),
      oauth_dependency(),
      oidc_dependency(),
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug_crypto, "~> 2.0"},
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

  defp custody_dependency do
    case System.get_env("ARBOR_CUSTODY_PATH") do
      nil -> {:arbor_custody, "~> 0.1.0-dev"}
      path -> {:arbor_custody, "~> 0.1.0-dev", path: path, override: true}
    end
  end

  defp support_dependency do
    case System.get_env("ARBOR_SUPPORT_PATH") do
      nil -> {:arbor_support, "~> 0.1.0-dev"}
      path -> {:arbor_support, "~> 0.1.0-dev", path: path, override: true}
    end
  end

  defp oauth_dependency do
    case System.get_env("ARBOR_OAUTH_PATH") do
      nil -> {:arbor_oauth, "~> 0.1.0-dev"}
      path -> {:arbor_oauth, "~> 0.1.0-dev", path: path, override: true}
    end
  end

  defp oidc_dependency do
    case System.get_env("ARBOR_CAPABILITIES_OIDC_PATH") do
      nil ->
        {:arbor_capabilities_oidc, "~> 0.1.0-dev", optional: true, runtime: false}

      path ->
        {:arbor_capabilities_oidc, "~> 0.1.0-dev",
         path: path, override: true, optional: true, runtime: false}
    end
  end
end
