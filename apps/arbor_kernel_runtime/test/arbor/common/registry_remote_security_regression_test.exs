defmodule Arbor.Common.RegistryRemoteSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  defmodule ExampleRegistry do
    use Arbor.Common.RegistryBase, table_name: :arbor_registry_remote_security_regression
  end

  defmodule AllowPolicy do
    def local_zone, do: 2
    def trust_zone(_), do: 0
    def can_resolve?(_, _), do: true
  end

  defmodule DenyPolicy do
    def local_zone, do: 2
    def trust_zone(_), do: 0
    def can_resolve?(_, _), do: false
  end

  defmodule MissingDecisionPolicy do
    def local_zone, do: 2
    def trust_zone(_), do: 0
  end

  defmodule BrokenPolicy do
    def local_zone, do: 2
    def trust_zone(_), do: 0

    def can_resolve?(_, _) do
      case Application.fetch_env!(:arbor_kernel, :registry_regression_decision) do
        :raise -> raise "policy unavailable"
        :exit -> exit(:policy_unavailable)
        :throw -> throw(:policy_unavailable)
        value -> value
      end
    end
  end

  defmodule InvalidZonePolicy do
    def local_zone, do: Application.fetch_env!(:arbor_kernel, :registry_regression_decision)
    def trust_zone(_), do: 0
    def can_resolve?(_, _), do: true
  end

  setup do
    prior_common = Application.fetch_env(:arbor_kernel, :common)
    prior_decision = Application.fetch_env(:arbor_kernel, :registry_regression_decision)

    on_exit(fn ->
      restore_env(:common, prior_common)
      restore_env(:registry_regression_decision, prior_decision)
    end)

    start_supervised!(ExampleRegistry)
    :ok = ExampleRegistry.reset()
    :ok = ExampleRegistry.register("example.local", String)
    :ok
  end

  test "security regression: missing remote policy denies before discovery while local lookup works" do
    for policy <- [
          nil,
          "not a module",
          %{},
          :arbor_missing_registry_policy,
          MissingDecisionPolicy
        ] do
      put_policy(policy)
      assert {:ok, String} = ExampleRegistry.resolve("example.local")

      assert {:error, {:zone_violation, _, _}} =
               ExampleRegistry.resolve("example.local", node: :remote@not_connected)
    end
  end

  test "security regression: unavailable and nonboolean remote decisions fail closed" do
    put_policy(BrokenPolicy)

    for decision <- [:raise, :exit, :throw, :allow, 1, nil] do
      Application.put_env(:arbor_kernel, :registry_regression_decision, decision)
      assert {:ok, String} = ExampleRegistry.resolve("example.local")

      assert {:error, {:zone_violation, 2, 0}} =
               ExampleRegistry.resolve("example.local", node: :remote@not_connected)
    end
  end

  test "security regression: cached remote lookup rechecks the current policy for both routes" do
    put_policy(AllowPolicy)
    seed_remote_cache()
    assert {:ok, String} = ExampleRegistry.resolve("cached.remote", node: :any)

    assert {:ok, String} =
             ExampleRegistry.resolve("cached.remote", node: :remote@not_connected)

    for policy <- [DenyPolicy, nil, MissingDecisionPolicy] do
      put_policy(policy)

      assert {:error, {:zone_violation, _, _}} =
               ExampleRegistry.resolve("cached.remote", node: :any)

      assert {:error, {:zone_violation, _, _}} =
               ExampleRegistry.resolve("cached.remote", node: :remote@not_connected)
    end
  end

  test "security regression: invalid zone evidence cannot be approved by a permissive policy" do
    put_policy(InvalidZonePolicy)
    seed_remote_cache()

    for zone <- [:unavailable, -1, 3, %{}] do
      Application.put_env(:arbor_kernel, :registry_regression_decision, zone)

      assert {:error, {:zone_violation, :unavailable, 0}} =
               ExampleRegistry.resolve("cached.remote", node: :any)
    end
  end

  test "default policy preserves the NodeRegistry facade and local decisions" do
    Application.put_env(:arbor_kernel, :common, trust_zones: :disabled)
    assert {:ok, String} = ExampleRegistry.resolve("example.local", node: :local)
    assert {:ok, String} = ExampleRegistry.resolve("example.local", node: node())

    seed_remote_cache()
    assert {:ok, String} = ExampleRegistry.resolve("cached.remote", node: :any)
  end

  test "security regression: default NodeRegistry zone changes apply to cached remote lookup" do
    Application.put_env(:arbor_kernel, :common,
      trust_zones: %{
        node() => %{zone: 2, apps: []},
        :remote@not_connected => %{zone: 1, apps: []}
      }
    )

    start_supervised!(Arbor.Common.NodeRegistry)
    seed_remote_cache()
    assert {:ok, String} = ExampleRegistry.resolve("cached.remote", node: :any)
    :ok = Arbor.Common.NodeRegistry.register_node(node(), %{zone: 0, apps: []})

    assert {:error, {:zone_violation, 0, 1}} =
             ExampleRegistry.resolve("cached.remote", node: :any)

    assert {:error, {:zone_violation, 0, 1}} =
             ExampleRegistry.resolve("cached.remote", node: :remote@not_connected)

    assert {:ok, String} = ExampleRegistry.resolve("example.local")
  end

  defp put_policy(policy) do
    Application.put_env(:arbor_kernel, :common, registry_distribution_policy: policy)
  end

  defp seed_remote_cache do
    # Fixture for a previously discovered entry; no distributed node is started.
    :ets.insert(
      :arbor_registry_remote_security_regression,
      {{:remote_cache, "cached.remote"}, String, :remote@not_connected,
       System.monotonic_time(:millisecond) + 30_000}
    )
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_kernel, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_kernel, key)
end
