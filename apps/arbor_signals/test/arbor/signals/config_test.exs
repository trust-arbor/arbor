defmodule Arbor.Signals.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Config
  alias Arbor.Signals.Config.Testing

  @legacy_keys [
    :durable_sink_module,
    :security_module,
    :crypto_module,
    :identity_registry_module,
    :start_children
  ]

  setup do
    Testing.isolate_namespace()
    legacy = Map.new(@legacy_keys, &{&1, snapshot_legacy_key(&1)})

    on_exit(fn ->
      Enum.each(legacy, fn {key, snapshot} -> restore_legacy_key(key, snapshot) end)
    end)

    :ok
  end

  test "durable sink seam defaults to nil" do
    Testing.delete(:durable_sink_module)
    delete_legacy(:durable_sink_module)
    assert Config.durable_sink_module() == nil
  end

  test "durable sink seam returns the configured module" do
    delete_legacy(:durable_sink_module)
    Testing.put(:durable_sink_module, __MODULE__.FakeSink)
    assert Config.durable_sink_module() == __MODULE__.FakeSink
  end

  test "durable sink seam returns invalid env raw" do
    delete_legacy(:durable_sink_module)
    Testing.put(:durable_sink_module, "not-a-module")
    assert Config.durable_sink_module() == "not-a-module"

    Testing.put(:durable_sink_module, true)
    assert Config.durable_sink_module() == true
  end

  test "security crypto and identity seams default to nil" do
    Testing.delete(:security_module)
    Testing.delete(:crypto_module)
    Testing.delete(:identity_registry_module)
    delete_legacy(:security_module)
    delete_legacy(:crypto_module)
    delete_legacy(:identity_registry_module)

    assert Config.security_module() == nil
    assert Config.crypto_module() == nil
    assert Config.identity_registry_module() == nil
  end

  test "security crypto and identity seams return the configured module" do
    delete_legacy(:security_module)
    delete_legacy(:crypto_module)
    delete_legacy(:identity_registry_module)
    Testing.put(:security_module, __MODULE__.FakeAuth)
    Testing.put(:crypto_module, __MODULE__.FakeCrypto)
    Testing.put(:identity_registry_module, __MODULE__.FakeKeys)

    assert Config.security_module() == __MODULE__.FakeAuth
    assert Config.crypto_module() == __MODULE__.FakeCrypto
    assert Config.identity_registry_module() == __MODULE__.FakeKeys
  end

  test "security crypto and identity seams return invalid env raw" do
    delete_legacy(:security_module)
    delete_legacy(:crypto_module)
    delete_legacy(:identity_registry_module)
    Testing.put(:security_module, "not-a-module")
    Testing.put(:crypto_module, true)
    Testing.put(:identity_registry_module, false)

    assert Config.security_module() == "not-a-module"
    assert Config.crypto_module() == true
    assert Config.identity_registry_module() == false
  end

  test "new-only kernel values win through owner getters" do
    delete_legacy(:durable_sink_module)
    Testing.put(:durable_sink_module, :kernel_only)
    assert Config.durable_sink_module() == :kernel_only

    delete_legacy(:start_children)
    Testing.put(:start_children, false)
    assert Config.start_children?() == false
  end

  test "legacy-only values win through owner getters" do
    Testing.delete(:durable_sink_module)
    put_legacy(:durable_sink_module, :legacy_only)
    assert Config.durable_sink_module() == :legacy_only

    Testing.delete(:start_children)
    put_legacy(:start_children, false)
    assert Config.start_children?() == false
  end

  test "equal dual values are admitted through owner getters" do
    Testing.put(:durable_sink_module, :same)
    put_legacy(:durable_sink_module, :same)
    assert Config.durable_sink_module() == :same

    Testing.put(:start_children, false)
    put_legacy(:start_children, false)
    assert Config.start_children?() == false
  end

  test "unequal dual values raise through owner getters" do
    Testing.put(:durable_sink_module, :kernel_value)
    put_legacy(:durable_sink_module, :legacy_value)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      Config.durable_sink_module()
    end

    Testing.put(:start_children, true)
    put_legacy(:start_children, false)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      Config.start_children?()
    end
  end

  test "configured nil is distinct from a missing start_children key" do
    delete_legacy(:start_children)
    Testing.put(:start_children, nil)
    assert Config.start_children?() == nil

    Testing.delete(:start_children)
    delete_legacy(:start_children)
    assert Config.start_children?() == true
  end

  test "configured nil on a nil-default seam is not treated as missing" do
    delete_legacy(:durable_sink_module)
    Testing.put(:durable_sink_module, nil)
    assert Config.durable_sink_module() == nil
  end

  test "namespace snapshot restores missing distinctly from configured nil" do
    Application.delete_env(:arbor_kernel, :signals)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, nil})
    assert Testing.snapshot_namespace() == {:ok, nil}

    Testing.restore_namespace(:error)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, [durable_sink_module: nil]})
    assert Testing.snapshot_namespace() == {:ok, [durable_sink_module: nil]}
    assert Config.durable_sink_module() == nil
  end

  test "test namespace mutations preserve map containers" do
    Testing.restore_namespace({:ok, %{durable_sink_module: :first, untouched: :kept}})
    Testing.put(:durable_sink_module, :second)

    assert Testing.get(:durable_sink_module) == :second
    assert Testing.get(:untouched) == :kept

    Testing.delete(:durable_sink_module)
    assert Testing.get(:durable_sink_module, :missing) == :missing
    assert Testing.get(:untouched) == :kept
  end

  test "only Signals.Config names ConfigCompat in production lib" do
    root = find_root(__DIR__)
    files = Path.wildcard(Path.join(root, "apps/arbor_signals/lib/**/*.ex"))
    assert files != []

    named =
      files
      |> Enum.filter(fn path -> File.read!(path) =~ "Arbor.Kernel.ConfigCompat" end)
      |> Enum.map(&Path.relative_to(&1, root))

    assert named == ["apps/arbor_signals/lib/arbor/signals/config.ex"]
  end

  defp snapshot_legacy_key(key), do: Application.fetch_env(:arbor_signals, key)

  defp restore_legacy_key(key, {:ok, value}), do: Application.put_env(:arbor_signals, key, value)
  defp restore_legacy_key(key, :error), do: Application.delete_env(:arbor_signals, key)

  defp put_legacy(key, value), do: Application.put_env(:arbor_signals, key, value)
  defp delete_legacy(key), do: Application.delete_env(:arbor_signals, key)

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end

  defmodule FakeSink do
  end

  defmodule FakeAuth do
  end

  defmodule FakeCrypto do
  end

  defmodule FakeKeys do
  end
end
