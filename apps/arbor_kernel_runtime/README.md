# Arbor Kernel Runtime

Active Common, Signals, and Monitor services for Arbor. The application composes
their existing supervisors under `Arbor.KernelRuntime.Supervisor` while keeping
configuration in the `:arbor_kernel` namespace. Passive contracts and types live
in `arbor_kernel`.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `arbor_kernel_runtime` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:arbor_kernel_runtime, "~> 0.1.0"}
  ]
end
```

The three nested service trees retain their individual child gates and
supervision strategies.
