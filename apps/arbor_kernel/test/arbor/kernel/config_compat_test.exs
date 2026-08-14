defmodule Arbor.Kernel.ConfigCompatTest do
  use ExUnit.Case, async: false

  alias Arbor.Kernel.ConfigCompat

  @moduletag :fast

  @owners [:arbor_contracts, :arbor_common, :arbor_signals, :arbor_monitor]
  @start_children_owners [:arbor_common, :arbor_signals, :arbor_monitor]
  @probe :k2_compat_probe
  @probe_conflict :k2_compat_probe_conflict

  setup do
    snapshot = snapshot_state(@owners, [@probe, @probe_conflict, :start_children])
    on_exit(fn -> restore_state(snapshot) end)
    :ok
  end

  test "legacy_owners/0 is the closed four-owner set" do
    assert ConfigCompat.legacy_owners() == @owners
  end

  test "kernel_path/2 prefixes the short namespace, not the retired app atom" do
    assert ConfigCompat.kernel_namespace(:arbor_contracts) == :contracts
    assert ConfigCompat.kernel_namespace(:arbor_common) == :common
    assert ConfigCompat.kernel_namespace(:arbor_signals) == :signals
    assert ConfigCompat.kernel_namespace(:arbor_monitor) == :monitor

    assert ConfigCompat.kernel_path(:arbor_common, :start_children) == [:common, :start_children]

    assert ConfigCompat.kernel_path(:arbor_signals, [:nested, :path]) == [
             :signals,
             :nested,
             :path
           ]

    assert ConfigCompat.kernel_path(:arbor_monitor, :start_children) == [
             :monitor,
             :start_children
           ]

    assert ConfigCompat.kernel_path(:arbor_contracts, :k) == [:contracts, :k]
  end

  test "rejects unknown legacy owners and non-atom runtime keys" do
    assert_raise ArgumentError, ~r/accepts only/, fn ->
      ConfigCompat.get_env(:arbor_security, @probe, :default)
    end

    assert_raise ArgumentError, ~r/accepts only/, fn ->
      ConfigCompat.fetch_env(:kernel, @probe)
    end

    assert_raise ArgumentError, ~r/must be atoms/, fn ->
      ConfigCompat.fetch_env(:arbor_common, [:nested, :path])
    end

    assert_raise ArgumentError, ~r/must be atoms/, fn ->
      ConfigCompat.get_env(:arbor_common, "skill_dirs", :default)
    end
  end

  test "runtime precedence table for each closed owner" do
    Enum.each(@owners, fn owner ->
      delete_kernel(owner, @probe)
      Application.delete_env(owner, @probe)

      assert ConfigCompat.get_env(owner, @probe, :caller_default) == :caller_default
      assert ConfigCompat.fetch_env(owner, @probe) == :error

      Application.put_env(owner, @probe, :legacy_only)
      assert ConfigCompat.get_env(owner, @probe, :caller_default) == :legacy_only
      assert ConfigCompat.fetch_env(owner, @probe) == {:ok, :legacy_only}

      put_kernel(owner, @probe, :kernel_only)
      Application.delete_env(owner, @probe)
      assert ConfigCompat.get_env(owner, @probe, :caller_default) == :kernel_only
      assert ConfigCompat.fetch_env(owner, @probe) == {:ok, :kernel_only}

      put_kernel(owner, @probe, :same)
      Application.put_env(owner, @probe, :same)
      assert ConfigCompat.get_env(owner, @probe, :caller_default) == :same
      assert ConfigCompat.fetch_env(owner, @probe) == {:ok, :same}

      put_kernel(owner, @probe, nil)
      Application.delete_env(owner, @probe)
      assert ConfigCompat.get_env(owner, @probe, :caller_default) == nil
      assert ConfigCompat.fetch_env(owner, @probe) == {:ok, nil}
    end)
  end

  test "unequal dual values reject instead of choosing" do
    put_kernel(:arbor_common, @probe_conflict, :kernel_value)
    Application.put_env(:arbor_common, @probe_conflict, :legacy_value)

    assert {:error, {:config_conflict, info}} =
             ConfigCompat.fetch_env(:arbor_common, @probe_conflict)

    assert info.legacy_app == :arbor_common
    assert info.key == @probe_conflict
    assert info.kernel == :kernel_value
    assert info.legacy == :legacy_value

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      ConfigCompat.get_env(:arbor_common, @probe_conflict, :unused)
    end

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      ConfigCompat.fetch_env!(:arbor_common, @probe_conflict)
    end
  end

  test "map and keyword namespaces distinguish configured nil from missing" do
    Application.delete_env(:arbor_common, @probe)
    Application.put_env(:arbor_kernel, :common, %{@probe => nil})
    assert ConfigCompat.fetch_env(:arbor_common, @probe) == {:ok, nil}
    assert ConfigCompat.get_env(:arbor_common, @probe, :caller_default) == nil

    Application.put_env(:arbor_kernel, :common, %{})
    assert ConfigCompat.fetch_env(:arbor_common, @probe) == :error
    assert ConfigCompat.get_env(:arbor_common, @probe, :caller_default) == :caller_default

    Application.put_env(:arbor_kernel, :common, [{@probe, nil}])
    assert ConfigCompat.fetch_env(:arbor_common, @probe) == {:ok, nil}

    Application.put_env(:arbor_kernel, :common, [])
    assert ConfigCompat.fetch_env(:arbor_common, @probe) == :error
  end

  test "malformed kernel namespaces raise ArgumentError instead of falling back" do
    Application.delete_env(:arbor_common, @probe)

    Application.put_env(:arbor_kernel, :common, "not-a-container")

    assert_raise ArgumentError, ~r/malformed :arbor_kernel namespace/, fn ->
      ConfigCompat.get_env(:arbor_common, @probe, :caller_default)
    end

    Application.put_env(:arbor_kernel, :common, nil)

    assert_raise ArgumentError, ~r/nil_namespace/, fn ->
      ConfigCompat.fetch_env(:arbor_common, @probe)
    end

    Application.put_env(:arbor_kernel, :common, [:not, :a, :keyword])

    assert_raise ArgumentError, ~r/not_keyword_or_map/, fn ->
      ConfigCompat.fetch_env!(:arbor_common, @probe)
    end

    Application.put_env(:arbor_kernel, :common, ~D[2026-08-14])

    assert_raise ArgumentError, ~r/malformed :arbor_kernel namespace/, fn ->
      ConfigCompat.get_env(:arbor_common, @probe, :unused)
    end

    Application.delete_env(:arbor_kernel, :common)
    assert ConfigCompat.fetch_env(:arbor_common, @probe) == :error
  end

  test "fetch_env! raises when neither side is configured" do
    delete_kernel(:arbor_monitor, @probe)
    Application.delete_env(:arbor_monitor, @probe)

    assert_raise ArgumentError, ~r/could not fetch/, fn ->
      ConfigCompat.fetch_env!(:arbor_monitor, @probe)
    end
  end

  # Indexed-source audit (literal Application.* and config keys on the four
  # closed owners): the only cross-owner atom is `:start_children` under
  # `:arbor_common`, `:arbor_signals`, and `:arbor_monitor`. `:arbor_contracts`
  # has no app-env keys. Owner namespacing is still used for every key so a
  # later collision cannot collapse into a flat `:arbor_kernel` key.
  test "owner-scoped start_children stay independent and conflicts stay pairwise" do
    Enum.each(@start_children_owners, fn owner ->
      Application.delete_env(owner, :start_children)
      Application.delete_env(:arbor_kernel, ConfigCompat.kernel_namespace(owner))
      Application.delete_env(:arbor_kernel, owner)
    end)

    Application.put_env(:arbor_kernel, :common, start_children: :common_kernel)
    Application.put_env(:arbor_kernel, :signals, start_children: :signals_kernel)
    Application.put_env(:arbor_kernel, :monitor, start_children: :monitor_kernel)

    assert ConfigCompat.get_env(:arbor_common, :start_children, :missing) == :common_kernel
    assert ConfigCompat.get_env(:arbor_signals, :start_children, :missing) == :signals_kernel
    assert ConfigCompat.get_env(:arbor_monitor, :start_children, :missing) == :monitor_kernel

    Application.put_env(:arbor_common, :start_children, :common_legacy)

    assert {:error, {:config_conflict, info}} =
             ConfigCompat.fetch_env(:arbor_common, :start_children)

    assert info.legacy_app == :arbor_common
    assert info.key == :start_children
    assert info.kernel == :common_kernel
    assert info.legacy == :common_legacy

    assert ConfigCompat.fetch_env(:arbor_signals, :start_children) == {:ok, :signals_kernel}
    assert ConfigCompat.fetch_env(:arbor_monitor, :start_children) == {:ok, :monitor_kernel}

    Application.put_env(:arbor_kernel, :start_children, :flat_collapsed)
    Application.put_env(:arbor_kernel, :arbor_signals, start_children: :retired_atom)

    assert ConfigCompat.get_env(:arbor_signals, :start_children, :missing) == :signals_kernel
    assert ConfigCompat.get_env(:arbor_monitor, :start_children, :missing) == :monitor_kernel
  end

  defp put_kernel(owner, key, value) do
    namespace = ConfigCompat.kernel_namespace(owner)

    current =
      case Application.fetch_env(:arbor_kernel, namespace) do
        {:ok, config} when is_list(config) -> config
        _ -> []
      end

    Application.put_env(:arbor_kernel, namespace, Keyword.put(current, key, value))
  end

  defp delete_kernel(owner, key) do
    namespace = ConfigCompat.kernel_namespace(owner)

    case Application.fetch_env(:arbor_kernel, namespace) do
      {:ok, config} when is_list(config) ->
        next = Keyword.delete(config, key)

        if next == [] do
          Application.delete_env(:arbor_kernel, namespace)
        else
          Application.put_env(:arbor_kernel, namespace, next)
        end

      _ ->
        :ok
    end
  end

  defp snapshot_state(owners, keys) do
    namespaces = Enum.map(owners, &ConfigCompat.kernel_namespace/1)

    kernel =
      Enum.map(namespaces ++ owners ++ [:start_children], fn key ->
        {{:arbor_kernel, key}, Application.fetch_env(:arbor_kernel, key)}
      end)

    legacy =
      for owner <- owners, key <- keys do
        {{owner, key}, Application.fetch_env(owner, key)}
      end

    kernel ++ legacy
  end

  defp restore_state(snapshot) do
    Enum.each(snapshot, fn
      {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
      {{app, key}, :error} -> Application.delete_env(app, key)
    end)
  end
end
