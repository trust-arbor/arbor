defmodule Arbor.Common.SkillImporterSecurityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.Config.Testing
  alias Arbor.Common.SkillImporter

  setup do
    Testing.isolate_namespace()

    dir = scratch_dir!(Path.join(File.cwd!(), "tmp"), "arbor-k1c-skill")
    write_skill(dir, "sample-skill", "A harmless imported skill body.")

    %{dir: dir}
  end

  @tag :security_regression
  test "security regression: missing scanner fails the import closed", %{dir: dir} do
    Testing.delete(:skill_import_security_module)

    assert {:error, :security_scanner_unavailable} = SkillImporter.import_from_directory(dir)
  end

  test "fake :ok admits the skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.OkProvider)

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == ["sample-skill"]
  end

  test "fake {:error, :blocked} excludes the skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.BlockedProvider)

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "finite provider errors exclude the skill", %{dir: dir} do
    for provider <- [
          __MODULE__.InvalidSkillProvider,
          __MODULE__.MalformedReflexProvider,
          __MODULE__.UnavailableProvider
        ] do
      Testing.put(:skill_import_security_module, provider)
      assert {:ok, result} = SkillImporter.import_from_directory(dir)
      assert imported_names(result) == []
    end
  end

  test "nonconforming {:error, :timeout} or {:error, \"boom\"} exclude the skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.TimeoutProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Testing.put(:skill_import_security_module, __MODULE__.BoomProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "fake {:warned, _} is a malformed Common result and excludes the skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.WarnedProvider)

    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "fake :blocked atom or map return excludes the skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.AtomProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Testing.put(:skill_import_security_module, __MODULE__.MapProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "provider raise, throw, or exit excludes the skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.RaisingProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Testing.put(:skill_import_security_module, __MODULE__.ThrowingProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []

    Testing.put(:skill_import_security_module, __MODULE__.ExitingProvider)
    assert {:ok, result} = SkillImporter.import_from_directory(dir)
    assert imported_names(result) == []
  end

  test "non-atom configured provider excludes the skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, "not-a-module")

    assert {:error, :security_scanner_unavailable} = SkillImporter.import_from_directory(dir)
  end

  @tag :security_regression
  test "security regression: every parsed field reaches the security provider", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.CapturingProvider)
    Testing.put(:skill_import_test_pid, self())

    assert {:ok, _result} = SkillImporter.import_from_directory(dir)
    assert_receive {:screened_body, screened_body}
    assert screened_body =~ "description"
    assert screened_body =~ "test skill"
  end

  @tag :security_regression
  test "security regression: screening rejects content rather than truncating parsed fields", %{
    dir: dir
  } do
    Testing.put(:skill_import_security_module, __MODULE__.OkProvider)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    write_skill(dir, "sample-skill", String.duplicate("a", 300_000))

    assert {:ok, %{count: 0, skills: []}} = SkillImporter.import_from_directory(dir)
  end

  @tag :security_regression
  test "security regression: directory resolution cannot fall back outside the trusted root" do
    outside = scratch_dir!(System.tmp_dir!(), "arbor-import-outside")
    write_skill(outside, "outside-skill", "outside")
    Testing.put(:skill_import_security_module, __MODULE__.OkProvider)

    assert {:error, {:path_traversal, ^outside}} =
             SkillImporter.import_from_directory(outside)
  end

  @tag :security_regression
  test "security regression: git importer rejects local and option-shaped repository URLs" do
    assert {:error, :unsupported_git_url} = SkillImporter.import_from_git("--upload-pack=evil")
    assert {:error, :unsupported_git_url} = SkillImporter.import_from_git("file:///tmp/repo")
  end

  @tag :security_regression
  test "security regression: untrusted overwrite cannot shadow a bundled skill", %{dir: dir} do
    Testing.put(:skill_import_security_module, __MODULE__.OkProvider)

    # The application indexes its configured directories asynchronously. Make
    # this security precondition explicit so the assertion does not depend on
    # scheduler timing or the Mix invocation's working directory.
    bundled = Application.app_dir(:arbor_kernel_runtime, "priv/library/skills")

    unless Process.whereis(Arbor.Common.SkillLibrary) do
      start_supervised!({Arbor.Common.SkillLibrary, dirs: [bundled]})
    end

    assert {:ok, bundled_count} = Arbor.Common.SkillLibrary.index(bundled)

    assert bundled_count > 0 or
             match?({:ok, _}, Arbor.Common.SkillLibrary.get("security-perspective"))

    assert {:ok, before} = Arbor.Common.SkillLibrary.get("security-perspective")
    assert before.taint == :trusted

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    write_skill(dir, "security-perspective", "attacker replacement")

    assert {:ok, %{count: 0}} =
             SkillImporter.import_from_directory(dir, approve: true, overwrite: true)

    assert {:ok, after_import} = Arbor.Common.SkillLibrary.get("security-perspective")
    assert after_import.taint == :trusted
    refute after_import.body =~ "attacker replacement"
  end

  defp imported_names(%{skills: skills}), do: Enum.map(skills, & &1.name)

  defp scratch_dir!(parent, prefix) do
    File.mkdir_p!(parent)
    {:ok, canonical_parent} = Arbor.Common.SafePath.resolve_real(parent)
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(canonical_parent, "#{prefix}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

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

  defmodule OkProvider do
    def validate_imported_skill(_skill), do: :ok
  end

  defmodule CapturingProvider do
    def validate_imported_skill(skill) do
      send(Arbor.Common.Config.Testing.get(:skill_import_test_pid), {:screened_body, skill.body})
      :ok
    end
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
