defmodule Arbor.Common.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.Config

  setup do
    originals = %{
      action: Application.get_env(:arbor_common, :action_capability_uri_module, :unset),
      skill: Application.get_env(:arbor_common, :skill_import_security_module, :unset)
    }

    on_exit(fn ->
      restore(:action_capability_uri_module, originals.action)
      restore(:skill_import_security_module, originals.skill)
    end)

    :ok
  end

  test "action and skill-import seams default to nil" do
    Application.delete_env(:arbor_common, :action_capability_uri_module)
    Application.delete_env(:arbor_common, :skill_import_security_module)

    assert Config.action_capability_uri_module() == nil
    assert Config.skill_import_security_module() == nil
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_common, key)
  defp restore(key, value), do: Application.put_env(:arbor_common, key, value)
end
