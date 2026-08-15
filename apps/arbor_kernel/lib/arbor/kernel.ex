defmodule Arbor.Kernel do
  @moduledoc """
  Passive owner of the `:arbor_kernel` application-env namespace.

  This OTP application has no supervision callback and no runtime children.
  It exists so `config :arbor_kernel, ...` is a real loaded application
  rather than an unavailable key that still applies with a Mix warning.

  Owner libraries store configuration under short namespaces because the
  retired app keyspaces are not disjoint:

      config :arbor_kernel, common: [...]
      config :arbor_kernel, signals: [...]
      config :arbor_kernel, monitor: [...]

  `:contracts` is reserved so it is not reused as a flat key. There is no
  `Arbor.Contracts.Config` in this packet. This application is not a public
  configuration wrapper; each owner library keeps its own `Arbor.*.Config`
  facade and reads only its namespace.
  """

  use Boundary,
    top_level?: true,
    deps: [],
    exports: []
end
