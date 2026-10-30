defmodule Arbor.Security.CodingUriCatalogSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security
  alias Arbor.Security.UriRegistry

  @observer_key :coding_uri_catalog_test_observer
  @read_prefix "arbor://coding/reconciliation/read"
  @apply_prefix "arbor://coding/reconciliation/apply"
  @lazy_catalog Arbor.Security.CodingUriCatalogSecurityRegressionTest.LazyCatalog
  @missing_catalog Arbor.Security.CodingUriCatalogSecurityRegressionTest.MissingCatalog
  @lazy_source """
  defmodule Arbor.Security.CodingUriCatalogSecurityRegressionTest.LazyCatalog do
    @moduledoc false
    @on_load :notice_loaded

    def notice_loaded do
      send(Application.fetch_env!(:arbor_security, :coding_uri_catalog_test_observer),
        {:catalog_loaded, __MODULE__})
      :ok
    end

    def capability_uri_prefixes do
      send(Application.fetch_env!(:arbor_security, :coding_uri_catalog_test_observer),
        {:catalog_invoked, __MODULE__, self()})
      ["arbor://coding/reconciliation/read", "arbor://coding/reconciliation/apply"]
    end
  end
  """

  defmodule Catalog do
    @moduledoc false

    def capability_uri_prefixes do
      send(
        Application.fetch_env!(:arbor_security, :coding_uri_catalog_test_observer),
        {:catalog_invoked, __MODULE__, self()}
      )

      ["arbor://coding/reconciliation/read", "arbor://coding/reconciliation/apply"]
    end
  end

  defmodule OtherCatalog do
    @moduledoc false

    def capability_uri_prefixes do
      send(
        Application.fetch_env!(:arbor_security, :coding_uri_catalog_test_observer),
        {:catalog_invoked, __MODULE__, self()}
      )

      ["arbor://catalog_other/read"]
    end
  end

  defmodule InvalidCatalog do
    @moduledoc false
    def capability_uri_prefixes, do: ["not-a-capability-uri"]
  end

  setup do
    keys = [
      :uri_registry_enforcement,
      :uri_registration_providers,
      :uri_bootstrap_providers,
      @observer_key
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_security, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    Application.put_env(:arbor_security, :uri_registry_enforcement, true)
    Application.put_env(:arbor_security, @observer_key, self())

    principal = "agent_coding_catalog_#{System.unique_integer([:positive])}"
    resource = @read_prefix <> "/" <> principal

    assert {:ok, capability} = Security.grant_fixture(principal: principal, resource: resource)
    assert capability.principal_id == principal
    assert capability.resource_uri == resource

    %{principal: principal, resource: resource}
  end

  test "security regression: absent coding feature denies a signed grant at public authorization",
       %{principal: principal, resource: resource} do
    start_registry!(start_profile: :full, registration_providers: [], bootstrap_providers: [])

    assert {:error, {:uri_rejected, :unregistered_uri}} =
             Security.authorize(principal, resource, :execute)

    refute Security.uri_registered?(resource)
    refute @read_prefix in UriRegistry.canonical_prefixes()
    refute @apply_prefix in UriRegistry.canonical_prefixes()
  end

  test "full bootstrap registers only the configured fixed projection", context do
    {_supervisor, registry} =
      start_registry!(
        start_profile: :full,
        registration_providers: [Catalog],
        bootstrap_providers: [Catalog]
      )

    assert_received {:catalog_invoked, Catalog, ^registry}

    assert {:ok, :authorized} =
             Security.authorize(context.principal, context.resource, :execute)

    assert @read_prefix in Security.registered_uri_prefixes()
    assert @apply_prefix in Security.registered_uri_prefixes()
    assert Security.uri_registered?(@apply_prefix <> "/validation_resource/resource_1")
    refute Security.uri_registered?("arbor://coding/reconciliation/reader/task_1")
    refute Security.uri_registered?("arbor://coding/reconciliation/applyx/resource_1")
    refute Security.uri_registered?("arbor://coding/other")
  end

  test "manual registration uses the same fixed allowlisted projection", context do
    {_supervisor, registry} =
      start_registry!(
        start_profile: :full,
        registration_providers: [Catalog],
        bootstrap_providers: []
      )

    assert {:error, {:uri_rejected, :unregistered_uri}} =
             Security.authorize(context.principal, context.resource, :execute)

    assert :ok = Security.register_uri_provider(Catalog)
    assert_received {:catalog_invoked, Catalog, ^registry}

    assert {:ok, :authorized} =
             Security.authorize(context.principal, context.resource, :execute)
  end

  test "security regression: later application configuration cannot expand a frozen allowlist" do
    start_registry!(start_profile: :full, registration_providers: [], bootstrap_providers: [])
    Application.put_env(:arbor_security, :uri_registration_providers, [Catalog])

    assert {:error, :uri_mutation_unauthorized} = Security.register_uri_provider(Catalog)
    refute_received {:catalog_invoked, _, _}
    refute Security.uri_registered?(@read_prefix <> "/task_1")
  end

  test "restart replays the original admitted providers instead of changed application env" do
    {supervisor, registry} =
      start_registry!(
        start_profile: :full,
        registration_providers: [Catalog],
        bootstrap_providers: [Catalog]
      )

    assert_received {:catalog_invoked, Catalog, ^registry}
    Application.put_env(:arbor_security, :uri_registration_providers, [OtherCatalog])
    Application.put_env(:arbor_security, :uri_bootstrap_providers, [OtherCatalog])
    monitor = Process.monitor(registry)
    assert :ok = Supervisor.terminate_child(supervisor, UriRegistry)
    assert_receive {:DOWN, ^monitor, :process, ^registry, _reason}, 5_000
    assert {:ok, restarted} = Supervisor.restart_child(supervisor, UriRegistry)
    refute restarted == registry
    assert_received {:catalog_invoked, Catalog, ^restarted}
    refute_received {:catalog_invoked, OtherCatalog, _}
    assert Security.uri_registered?(@read_prefix <> "/task_1")
    refute Security.uri_registered?("arbor://catalog_other/read/task_1")
  end

  test "security regression: activation-only bootstrap and manual requests never load a provider" do
    prepare_unloaded_catalog!()
    Application.put_env(:arbor_security, :uri_registration_providers, [@lazy_catalog])

    start_registry!(
      start_profile: :activation_only,
      registration_providers: [@lazy_catalog],
      bootstrap_providers: [@lazy_catalog]
    )

    assert :code.is_loaded(@lazy_catalog) == false
    refute_received {:catalog_loaded, @lazy_catalog}
    refute_received {:catalog_invoked, @lazy_catalog, _}
    assert {:error, :uri_mutation_unauthorized} = Security.register_uri_provider(@lazy_catalog)
    assert :code.is_loaded(@lazy_catalog) == false
    refute_received {:catalog_loaded, @lazy_catalog}
    refute_received {:catalog_invoked, @lazy_catalog, _}
    refute Security.uri_registered?(@read_prefix <> "/task_1")
  end

  test "security regression: unavailable, unallowlisted, and malformed full bootstrap fails closed" do
    for {providers, bootstrap} <- [
          {[], [Catalog]},
          {[@missing_catalog], [@missing_catalog]},
          {[InvalidCatalog], [InvalidCatalog]}
        ] do
      assert {:error, _reason} =
               start_supervised(
                 {UriRegistry,
                  start_profile: :full,
                  registration_providers: providers,
                  bootstrap_providers: bootstrap}
               )

      assert Process.whereis(UriRegistry) == nil
      refute_received {:catalog_invoked, Catalog, _}
    end
  end

  defp start_registry!(opts) do
    supervisor =
      start_supervised!(%{
        id: {__MODULE__, :registry_fixture},
        type: :supervisor,
        start: {Supervisor, :start_link, [[{UriRegistry, opts}], [strategy: :one_for_one]]}
      })

    [{UriRegistry, registry, :worker, _modules}] = Supervisor.which_children(supervisor)
    {supervisor, registry}
  end

  defp prepare_unloaded_catalog! do
    root =
      Path.join(
        System.tmp_dir!(),
        "coding-uri-catalog-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(root)
    # The complete source is a fixed fixture above; no external text is compiled.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    [{@lazy_catalog, beam}] = Code.compile_string(@lazy_source)
    assert_receive {:catalog_loaded, @lazy_catalog}, 5_000
    File.write!(Path.join(root, "#{@lazy_catalog}.beam"), beam)
    true = :code.add_patha(String.to_charlist(root))
    :code.purge(@lazy_catalog)
    true = :code.delete(@lazy_catalog)
    :code.purge(@lazy_catalog)
    assert :code.is_loaded(@lazy_catalog) == false

    on_exit(fn ->
      :code.del_path(String.to_charlist(root))
      :code.purge(@lazy_catalog)
      :code.delete(@lazy_catalog)
      :code.purge(@lazy_catalog)
      File.rm_rf!(root)
    end)
  end
end
