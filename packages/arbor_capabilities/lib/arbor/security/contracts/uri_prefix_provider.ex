defmodule Arbor.Security.Contracts.UriPrefixProvider do
  @moduledoc """
  Fixed capability URI projection supplied by a trusted host feature.

  The provider returns canonical prefixes independently of feature runtime
  state. Projection must be synchronous, pure and non-blocking. Security
  admits only host-allowlisted providers; callers cannot supply prefix bytes.
  Full-profile startup may activate an explicitly configured provider, and
  registry restart replays the admitted projection. Activation-only startup
  never loads or invokes providers.
  """

  @callback capability_uri_prefixes() :: [String.t()]
end
