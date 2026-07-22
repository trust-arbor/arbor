defmodule Arbor.Security.UriRegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.UriRegistry

  setup do
    unless Process.whereis(UriRegistry) do
      start_supervised!({UriRegistry, []})
    end

    original_enforcement = Application.get_env(:arbor_security, :uri_registry_enforcement)

    on_exit(fn ->
      restore_env(:uri_registry_enforcement, original_enforcement)
    end)

    :ok
  end

  describe "registered?/1" do
    test "security regression: singular action prefix does not match retired plural actions namespace" do
      refute "arbor://action" in UriRegistry.canonical_prefixes()
      refute UriRegistry.registered?("arbor://actions/execute/git.status")
    end

    test "matches canonical prefixes on segment boundaries" do
      assert UriRegistry.registered?("arbor://fs/read/project/src")
      refute UriRegistry.registered?("arbor://fs/reader/project/src")

      assert UriRegistry.registered?("arbor://tool/use/websearch")
      refute UriRegistry.registered?("arbor://tool/useful/websearch")

      assert UriRegistry.registered?("arbor://agent/spawn_worker")
      assert UriRegistry.registered?("arbor://agent/task/cancel/task_1")
      assert UriRegistry.registered?("arbor://agent/task/steer/task_1")
      assert UriRegistry.registered?("arbor://agent/task/adopt/task_1")
      refute UriRegistry.registered?("arbor://agent/task/adoption/task_1")

      assert UriRegistry.registered?("arbor://coding/reconciliation/read/task_1")
      refute UriRegistry.registered?("arbor://coding/reconciliation/reader/task_1")
    end

    test "supports trailing-slash canonical prefixes" do
      assert UriRegistry.registered?("arbor://mcp/server")
      refute UriRegistry.registered?("arbor://mcproxy/server")
    end
  end

  describe "Arbor.Security.uri_registered?/1" do
    test "exposes canonical and runtime URI membership through the facade" do
      prefix = "arbor://facade_runtime_#{System.unique_integer([:positive])}/op"

      assert :ok = Arbor.Security.register_uri_prefix(prefix)
      assert Arbor.Security.uri_registered?("arbor://fs/read/project/src")
      assert Arbor.Security.uri_registered?(prefix <> "/child")
      refute Arbor.Security.uri_registered?(prefix <> "posite/child")
    end
  end

  describe "validate/1" do
    test "valid unknown URIs honor enforcement mode" do
      Application.put_env(:arbor_security, :uri_registry_enforcement, false)
      assert :ok = UriRegistry.validate("arbor://unknown/path")

      Application.put_env(:arbor_security, :uri_registry_enforcement, true)
      assert {:error, :unregistered_uri} = UriRegistry.validate("arbor://unknown/path")
    end

    test "invalid URIs fail closed even when enforcement is disabled" do
      Application.put_env(:arbor_security, :uri_registry_enforcement, false)

      assert {:error, {:invalid_uri, :invalid_scheme}} =
               UriRegistry.validate("https://example.com")

      assert {:error, {:invalid_uri, :empty_segment}} =
               UriRegistry.validate("arbor://fs//read")
    end
  end

  describe "register/1" do
    test "runtime prefixes use segment-aware matching" do
      prefix = "arbor://custom_runtime_#{System.unique_integer([:positive])}/op"

      assert :ok = UriRegistry.register(prefix)
      assert UriRegistry.registered?(prefix <> "/child")
      refute UriRegistry.registered?(prefix <> "posite/child")
    end

    test "rejects invalid runtime prefixes" do
      assert {:error, {:invalid_uri, :invalid_scheme}} =
               UriRegistry.register("not-a-uri")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
