defmodule Arbor.Security.UriRegistryForgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.UriRegistry

  setup do
    unless Process.whereis(UriRegistry) do
      start_supervised!({UriRegistry, []})
    end

    :ok
  end

  test "forge project namespace is canonical and segment-aware" do
    assert "arbor://forge/project" in UriRegistry.canonical_prefixes()
    assert UriRegistry.registered?("arbor://forge/project/acme/arbor")
    refute UriRegistry.registered?("arbor://forge/projector/x")
  end
end
