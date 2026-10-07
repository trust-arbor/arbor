defmodule Arbor.Common.RegistryIntegritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-007"

  @moduletag :fast

  defmodule LockedRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :arbor_registry_integrity_security_regression,
      allow_test_mutations: false
  end

  defmodule HandlerContract do
    @callback execute(term(), term(), term(), keyword()) :: term()
  end

  defmodule DeclaredHandler do
    @behaviour HandlerContract
    @impl true
    def execute(_node, _context, _graph, _opts), do: :ok
  end

  defmodule UndeclaredHandler do
    def execute(_node, _context, _graph, _opts), do: :ok
  end

  @tag :security_regression
  @tag spec: "KSEC-007"
  test "security regression: core registry state is owner protected and mutation APIs are test-only" do
    start_supervised!(LockedRegistry)
    assert :ok = LockedRegistry.register("core", String)
    snapshot = LockedRegistry.snapshot()
    assert :ok = LockedRegistry.lock_core()

    assert :protected == :ets.info(:arbor_registry_integrity_security_regression, :protection)

    assert_raise ArgumentError, fn ->
      :ets.insert(
        :arbor_registry_integrity_security_regression,
        {"core", List, %{}, 0, true}
      )
    end

    snapshot_key = {LockedRegistry, :core_snapshot}
    :persistent_term.put(snapshot_key, %{"core" => List})
    on_exit(fn -> :persistent_term.erase(snapshot_key) end)

    assert {:ok, String} = LockedRegistry.resolve("core")
    assert {:error, :test_only} = LockedRegistry.reset()
    assert {:error, :test_only} = LockedRegistry.restore(snapshot)
    assert {:ok, String} = LockedRegistry.resolve("core")
  end

  @tag :security_regression
  test "security regression: HandlerRegistry requires a declared execute/4 behaviour" do
    if Process.whereis(Arbor.Common.HandlerRegistry) == nil do
      start_supervised!(Arbor.Common.HandlerRegistry)
    end

    suffix = System.unique_integer([:positive])

    assert {:error, {:missing_handler_behaviour, {:execute, 4}}} =
             Arbor.Common.HandlerRegistry.register(
               "security_regression.undeclared_#{suffix}",
               UndeclaredHandler
             )

    assert :ok =
             Arbor.Common.HandlerRegistry.register(
               "security_regression.declared_#{suffix}",
               DeclaredHandler
             )
  end
end
