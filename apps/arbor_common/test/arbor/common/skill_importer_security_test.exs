defmodule Arbor.Common.SkillImporterSecurityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SkillImporter

  setup do
    original = Application.get_env(:arbor_common, :skill_import_security_module, :unset)
    dir = Path.join(System.tmp_dir!(), "arbor_k1c_skill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    write_skill(dir, "sample-skill", "A harmless imported skill body.")

    on_exit(fn ->
      File.rm_rf(dir)
      restore(:skill_import_security_module, original)
    end)

    %{dir: dir}
  end

  test "standalone no-provider policy admits a parsed skill", %{dir: dir} do
    Application.delete_env(:arbor_common, :skill_import_security_module)

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == ["sample-skill"]
  end

  test "fake :ok admits the skill", %{dir: dir} do
    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.OkProvider)

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == ["sample-skill"]
  end

  test "fake {:error, :blocked} excludes the skill", %{dir: dir} do
    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.BlockedProvider)

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "finite provider errors exclude the skill", %{dir: dir} do
    for provider <- [
          __MODULE__.InvalidSkillProvider,
          __MODULE__.MalformedReflexProvider,
          __MODULE__.UnavailableProvider
        ] do
      Application.put_env(:arbor_common, :skill_import_security_module, provider)
      assert {:ok, result} = SkillImporter.import_from_directory(dir)
      assert imported_names(result) == []
    end
  end

  test "nonconforming {:error, :timeout} or {:error, \"boom\"} exclude the skill", %{dir: dir} do
    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.TimeoutProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.BoomProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "fake {:warned, _} is a malformed Common result and excludes the skill", %{dir: dir} do
    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.WarnedProvider)

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "fake :blocked atom or map return excludes the skill", %{dir: dir} do
    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.AtomProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.MapProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "provider raise, throw, or exit excludes the skill", %{dir: dir} do
    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.RaisingProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.ThrowingProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Application.put_env(:arbor_common, :skill_import_security_module, __MODULE__.ExitingProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "non-atom configured provider excludes the skill", %{dir: dir} do
    Application.put_env(:arbor_common, :skill_import_security_module, "not-a-module")

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  defp imported_names(%{skills: skills}), do: Enum.map(skills, & &1.name)

  defp write_skill(dir, name, body) do
    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: test skill
    ---

    #{body}
    """)
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_common, key)
  defp restore(key, value), do: Application.put_env(:arbor_common, key, value)

  defmodule OkProvider do
    def validate_imported_skill(_skill), do: :ok
  end

  defmodule BlockedProvider do
    def validate_imported_skill(_skill), do: {:error, :blocked}
  end

  defmodule InvalidSkillProvider do
    def validate_imported_skill(_skill), do: {:error, :invalid_skill}
  end

  defmodule MalformedReflexProvider do
    def validate_imported_skill(_skill), do: {:error, :malformed_reflex_result}
  end

  defmodule UnavailableProvider do
    def validate_imported_skill(_skill), do: {:error, :reflex_unavailable}
  end

  defmodule TimeoutProvider do
    def validate_imported_skill(_skill), do: {:error, :timeout}
  end

  defmodule BoomProvider do
    def validate_imported_skill(_skill), do: {:error, "boom"}
  end

  defmodule WarnedProvider do
    def validate_imported_skill(_skill), do: {:warned, [:localhost]}
  end

  defmodule AtomProvider do
    def validate_imported_skill(_skill), do: :blocked
  end

  defmodule MapProvider do
    def validate_imported_skill(_skill), do: %{ok: false}
  end

  defmodule RaisingProvider do
    def validate_imported_skill(_skill), do: raise("provider boom")
  end

  defmodule ThrowingProvider do
    def validate_imported_skill(_skill), do: throw(:provider_throw)
  end

  defmodule ExitingProvider do
    def validate_imported_skill(_skill), do: exit(:provider_exit)
  end
end
