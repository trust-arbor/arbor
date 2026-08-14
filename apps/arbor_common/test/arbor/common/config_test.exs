defmodule Arbor.Common.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.Config
  alias Arbor.Common.Config.Testing

  @legacy_keys [
    :action_capability_uri_module,
    :hands,
    :skill_import_security_module,
    :skill_embedding_module,
    :start_children,
    :tool_catalog_enabled
  ]

  setup do
    Testing.isolate_namespace()
    legacy = Map.new(@legacy_keys, &{&1, Testing.snapshot_legacy_key(&1)})

    on_exit(fn ->
      Enum.each(legacy, fn {key, snapshot} -> Testing.restore_legacy_key(key, snapshot) end)
    end)

    :ok
  end

  test "action and skill-import seams default to nil" do
    Testing.delete(:action_capability_uri_module)
    Testing.delete(:skill_import_security_module)
    Testing.delete_legacy(:action_capability_uri_module)
    Testing.delete_legacy(:skill_import_security_module)

    assert Config.action_capability_uri_module() == nil
    assert Config.skill_import_security_module() == nil
  end

  test "test config deep-merges base Common keys with the environment override" do
    Testing.delete_legacy(:tool_catalog_enabled)
    Testing.delete_legacy(:start_children)
    Testing.delete_legacy(:hands)

    assert Config.tool_catalog_enabled?() == true
    assert Config.start_children?() == false
    assert is_list(Config.hands())
    assert Config.hands()[:sandbox_image] == "claude-sandbox"
  end

  test "new-only kernel values win through owner getters" do
    Testing.delete_legacy(:skill_embedding_module)
    Testing.put(:skill_embedding_module, :kernel_only)
    assert Config.skill_embedding_module() == :kernel_only

    Testing.delete_legacy(:start_children)
    Testing.put(:start_children, false)
    assert Config.start_children?() == false
  end

  test "legacy-only values win through owner getters" do
    Testing.delete(:skill_embedding_module)
    Testing.put_legacy(:skill_embedding_module, :legacy_only)
    assert Config.skill_embedding_module() == :legacy_only

    Testing.delete(:start_children)
    Testing.put_legacy(:start_children, false)
    assert Config.start_children?() == false
  end

  test "equal dual values are admitted through owner getters" do
    Testing.put(:skill_embedding_module, :same)
    Testing.put_legacy(:skill_embedding_module, :same)
    assert Config.skill_embedding_module() == :same

    Testing.put(:start_children, false)
    Testing.put_legacy(:start_children, false)
    assert Config.start_children?() == false
  end

  test "unequal dual values raise through owner getters" do
    Testing.put(:skill_embedding_module, :kernel_value)
    Testing.put_legacy(:skill_embedding_module, :legacy_value)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      Config.skill_embedding_module()
    end

    Testing.put(:start_children, true)
    Testing.put_legacy(:start_children, false)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      Config.start_children?()
    end
  end

  test "configured nil is distinct from a missing start_children key" do
    Testing.delete_legacy(:start_children)
    Testing.put(:start_children, nil)
    assert Config.start_children?() == nil

    Testing.delete(:start_children)
    Testing.delete_legacy(:start_children)
    assert Config.start_children?() == true
  end

  test "configured nil on a nil-default seam is not treated as missing" do
    Testing.delete_legacy(:skill_embedding_module)
    Testing.put(:skill_embedding_module, nil)
    assert Config.skill_embedding_module() == nil
  end

  test "namespace snapshot restores missing distinctly from configured nil" do
    Application.delete_env(:arbor_kernel, :common)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, nil})
    assert Testing.snapshot_namespace() == {:ok, nil}

    Testing.restore_namespace(:error)
    assert Testing.snapshot_namespace() == :error

    Testing.restore_namespace({:ok, [skill_embedding_module: nil]})
    assert Testing.snapshot_namespace() == {:ok, [skill_embedding_module: nil]}
    assert Config.skill_embedding_module() == nil
  end

  test "test namespace mutations preserve map containers" do
    Testing.restore_namespace({:ok, %{skill_embedding_module: :first, untouched: :kept}})
    Testing.put(:skill_embedding_module, :second)

    assert Testing.get(:skill_embedding_module) == :second
    assert Testing.get(:untouched) == :kept

    Testing.delete(:skill_embedding_module)
    assert Testing.get(:skill_embedding_module, :missing) == :missing
    assert Testing.get(:untouched) == :kept
  end
end
