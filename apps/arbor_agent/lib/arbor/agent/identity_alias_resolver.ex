defmodule Arbor.Agent.IdentityAliasResolver do
  @moduledoc """
  Persistence-backed `Arbor.Security.IdentityAlias` resolver.

  The contract lives in `arbor_security` (L2) so anything comparing principal
  ids can reach it; the alias records live in `Arbor.Persistence.BufferedStore`
  (L3), which that library may not depend on. This module is the seam: it sits
  in `arbor_agent`, which already depends on both, and is registered at startup.

  Distinguishes "no alias" from "cannot tell":

    * an id with no alias record resolves to ITSELF — a successful resolution
    * an unavailable store returns `{:error, :alias_store_unavailable}`

  `IdentityAliases.resolve/1` collapses both into "return the input id", which
  is fine for display but unsafe for an authorization comparison — a caller
  cannot distinguish a genuine primary from a store outage.
  """

  @behaviour Arbor.Security.IdentityAlias

  alias Arbor.Agent.IdentityAliases

  @impl true
  def resolve(id) when is_binary(id) do
    if IdentityAliases.available?() do
      {:ok, IdentityAliases.resolve(id)}
    else
      {:error, :alias_store_unavailable}
    end
  end
end
