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

  test "retired continuation prefix remains unknown (security regression)" do
    prefix = "arbor://orchestrator/cross_app_continuation"
    continuation_id = "xappc_" <> String.duplicate("a", 64)

    refute prefix in UriRegistry.canonical_prefixes()
    refute UriRegistry.registered?(prefix)
    refute UriRegistry.registered?("#{prefix}/#{continuation_id}/get")
    refute UriRegistry.registered?("#{prefix}/#{continuation_id}/claim/op-1")
    refute UriRegistry.registered?("#{prefix}/journal/durability_status")
    refute UriRegistry.registered?("#{prefix}/journal/refresh")
  end
end
