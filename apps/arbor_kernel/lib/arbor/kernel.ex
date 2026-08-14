defmodule Arbor.Kernel do
  @moduledoc """
  Passive owner of the `:arbor_kernel` application-env namespace.

  This OTP application has no supervision callback and no runtime children.
  It exists so `config :arbor_kernel, ...` is a real loaded application
  rather than an unavailable key that still applies with a Mix warning.

  Temporary migration reads for the four retired owners live in
  `Arbor.Kernel.ConfigCompat`. Kernel storage uses short namespaces
  (`:contracts`, `:common`, `:signals`, `:monitor`) because legacy
  keyspaces are not disjoint. That module is not permanent public
  configuration infrastructure: a later K2 packet will directize remaining
  reads to `:arbor_kernel` and delete the seam after the app-env inventory
  reaches zero.
  """
end
