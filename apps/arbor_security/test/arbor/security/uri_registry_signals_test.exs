defmodule Arbor.Security.UriRegistrySignalsTest do
  @moduledoc """
  Security regression: the `arbor://signals/subscribe` namespace must be in the
  canonical URI registry. It is used in live authorization (Signals.Bus →
  CapabilityAuthorizer builds `arbor://signals/subscribe/<topic>` and calls
  Security.authorize), but was absent from the registry — so with URI-registry
  enforcement enabled, a legitimate signal-subscription capability could be
  rejected as unregistered. (Security Sentinel finding, 2026-06-09.)

  Fails on `git checkout HEAD~1` of the registration.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.UriRegistry

  test "the signals/subscribe prefix is canonical" do
    assert "arbor://signals/subscribe" in UriRegistry.canonical_prefixes()
  end

  test "a concrete signals subscription URI is recognized as registered" do
    assert UriRegistry.registered?("arbor://signals/subscribe/security")
    assert UriRegistry.registered?("arbor://signals/subscribe/identity")
  end
end
