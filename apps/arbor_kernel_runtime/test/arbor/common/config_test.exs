defmodule Arbor.Common.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.Config
  alias Arbor.Common.Config.Testing

  setup do
    Testing.isolate_namespace()
    :ok
  end

  test "action and skill-import seams default to nil" do
    Testing.delete(:action_capability_uri_module)
    Testing.delete(:skill_import_security_module)

    assert Config.action_capability_uri_module() == nil
    assert Config.skill_import_security_module() == nil
  end

  test "test config deep-merges base Common keys with the environment override" do
    assert Config.tool_catalog_enabled?() == false
    assert Config.start_children?() == false
    assert is_list(Config.hands())
    assert Config.hands()[:sandbox_image] == "claude-sandbox"
  end

  test "kernel values are visible through owner getters" do
    Testing.put(:skill_embedding_module, :kernel_only)
    assert Config.skill_embedding_module() == :kernel_only

    Testing.put(:start_children, false)
    assert Config.start_children?() == false
  end

  test "configured nil is distinct from a missing start_children key" do
    Testing.put(:start_children, nil)
    assert Config.start_children?() == nil

    Testing.delete(:start_children)
    assert Config.start_children?() == true
  end

  test "configured nil on a nil-default seam is not treated as missing" do
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

    assert Config.skill_embedding_module() == :second
    assert Testing.get(:skill_embedding_module) == :second
    assert Testing.get(:untouched) == :kept

    Testing.delete(:skill_embedding_module)
    assert Testing.get(:skill_embedding_module, :missing) == :missing
    assert Testing.get(:untouched) == :kept
  end

  test "malformed namespace containers raise through owner getters" do
    Enum.each([nil, [:not_a_keyword], ~D[2026-08-14]], fn malformed ->
      Testing.restore_namespace({:ok, malformed})

      assert_raise ArgumentError, ~r/malformed :arbor_kernel :common namespace/, fn ->
        Config.skill_embedding_module()
      end
    end)
  end
end
