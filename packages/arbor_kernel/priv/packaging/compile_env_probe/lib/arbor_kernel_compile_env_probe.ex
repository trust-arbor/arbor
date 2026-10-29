# Probe-only fixture; not a production release.
defmodule ArborKernelCompileEnvProbe do
  @value Application.compile_env(:arbor_kernel, [:common, :k2e_compile_probe], :missing)
  def value, do: @value
end
