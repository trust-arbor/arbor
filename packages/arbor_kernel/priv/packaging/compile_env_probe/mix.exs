# Probe-only fixture; not a production release.
# Relative path is illustrative. Tests rewrite a temp copy to an absolute path.
defmodule ArborKernelCompileEnvProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_kernel_compile_env_probe,
      version: "0.0.0",
      elixir: "~> 1.17",
      deps: [{:arbor_kernel, path: "../../.."}]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end
end
