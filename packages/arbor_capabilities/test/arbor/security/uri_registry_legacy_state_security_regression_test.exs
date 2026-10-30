defmodule Arbor.Security.UriRegistryLegacyStateSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security
  alias Arbor.Security.UriRegistry

  @observer_key :uri_registry_legacy_test_observer

  defmodule Catalog do
    def capability_uri_prefixes do
      send(
        Application.fetch_env!(:arbor_capabilities, :uri_registry_legacy_test_observer),
        :legacy_catalog_invoked
      )

      ["arbor://legacy_catalog/read"]
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_capabilities, @observer_key)
    Application.put_env(:arbor_capabilities, @observer_key, self())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_capabilities, @observer_key, value)
        :error -> Application.delete_env(:arbor_capabilities, @observer_key)
      end
    end)

    :ok
  end

  test "security regression: a legacy registry refuses new activation without crashing its owner" do
    registry =
      start_supervised!(
        {UriRegistry,
         start_profile: :full, registration_providers: [Catalog], bootstrap_providers: []}
      )

    # This is the complete state retained by the pre-bootstrap registry. A plain
    # module reload does not invoke code_change or replace the serving process.
    :sys.replace_state(registry, fn _current -> %{provider_prefixes: %{}} end)

    for _ <- 1..3 do
      assert {:error, :uri_registry_unavailable} = Security.register_uri_provider(Catalog)
      assert Process.alive?(registry)
      assert Process.whereis(UriRegistry) == registry
      refute_received :legacy_catalog_invoked
    end

    assert Security.uri_registered?("arbor://fs/read/project")
    refute Security.uri_registered?("arbor://legacy_catalog/read/project")
  end
end
