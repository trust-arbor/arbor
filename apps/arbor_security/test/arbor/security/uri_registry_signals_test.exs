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

  # Security Sentinel URI-inventory triage (2026-06-09): two action-backed /
  # actively-authorized namespaces were granted/used but unregistered, so with
  # enforcement on they were rejected as :unregistered_uri. These assert the gap
  # is closed; they fail on revert of the registry additions.
  test "the H13 auto-promote gate URI is registered" do
    # registered?/1 reflects canonical membership regardless of the enforcement
    # config (which is off in test), so it's the meaningful fail-on-revert check.
    assert UriRegistry.registered?("arbor://trust/auto_promote/agent_target123")
  end

  test "the composition dispatch capability URI is registered" do
    assert UriRegistry.registered?("arbor://orchestrator/map/dispatch")
  end

  test "the gateway tool-use and status URIs are registered (authorized at call-site)" do
    assert UriRegistry.registered?("arbor://tool/use/websearch")
    assert UriRegistry.registered?("arbor://status/orchestrator/agent_x")
  end

  test "orchestrator handler + pipeline capability URIs are registered (live infra)" do
    assert UriRegistry.registered?("arbor://handler/compute/llm")
    assert UriRegistry.registered?("arbor://handler/read/file/read")
    assert UriRegistry.registered?("arbor://pipeline/run")
  end

  test "the governance ceiling namespace is registered" do
    assert UriRegistry.registered?("arbor://governance/change/self/foo")
  end
end
