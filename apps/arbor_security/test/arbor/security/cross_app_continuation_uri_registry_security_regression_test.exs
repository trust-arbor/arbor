defmodule Arbor.Security.CrossAppContinuationUriRegistrySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :security_regression

  alias Arbor.Security.UriRegistry

  setup do
    unless Process.whereis(UriRegistry) do
      start_supervised!({UriRegistry, []})
    end

    :ok
  end

  test "continuation namespace is canonical and segment-aware" do
    prefix = "arbor://orchestrator/cross_app_continuation"
    continuation_id = "xappc_" <> String.duplicate("a", 64)

    assert prefix in UriRegistry.canonical_prefixes()
    assert UriRegistry.registered?("#{prefix}/#{continuation_id}/get")
    assert UriRegistry.registered?("#{prefix}/#{continuation_id}/claim/op-1")
    assert UriRegistry.registered?("#{prefix}/journal/durability_status")
    assert UriRegistry.registered?("#{prefix}/journal/refresh")
    refute UriRegistry.registered?("#{prefix}s/#{continuation_id}/get")
    refute UriRegistry.registered?("#{prefix}_evil/#{continuation_id}/get")
  end
end
