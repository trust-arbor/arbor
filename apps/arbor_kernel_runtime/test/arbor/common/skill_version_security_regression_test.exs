defmodule Arbor.Common.SkillVersionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.{CapabilityProviders.SkillProvider, SkillLibrary}
  alias Arbor.Common.SkillLibrary.SkillAdapter

  @moduletag :fast
  @moduletag :security_regression

  setup do
    unless Process.whereis(SkillLibrary), do: start_supervised!({SkillLibrary, dirs: []})
    previous = Application.fetch_env(:arbor_kernel, :common)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_kernel, :common, value)
        :error -> Application.delete_env(:arbor_kernel, :common)
      end
    end)

    name = "version-test-#{System.unique_integer([:positive])}"

    :ok =
      SkillLibrary.register(%{
        name: name,
        description: "test",
        body: "REVIEWED {{topic}}",
        taint: :untrusted,
        allowed_tools: [],
        metadata: %{}
      })

    %{name: name}
  end

  @tag :trusted_skill_bug
  test "capability resolver execution cannot promote an unapproved skill body", %{name: name} do
    assert {:error, _} =
             SkillProvider.execute("skill:" <> name, %{bindings: %{"topic" => "data"}}, [])
  end

  test "source-owned pins admit exact snapshots and drift returns fallback", %{name: name} do
    {:ok, version} = SkillLibrary.prepare_approval(name)
    common = Application.get_env(:arbor_kernel, :common, [])

    Application.put_env(
      :arbor_kernel,
      :common,
      Keyword.put(common, :trusted_skill_versions, %{name => version.digest})
    )

    assert {:ok, %{body: body, taint: :untrusted, version_digest: digest}} =
             SkillProvider.execute("prompt:" <> name, %{bindings: %{"topic" => "data"}}, [])

    assert body == "REVIEWED data"
    assert digest == version.digest

    assert {:ok, %{builtin_versions: [%{state: "pinned"}]}} =
             SkillLibrary.version_manifest("absent", [])

    :ok = SkillLibrary.register(Map.put(version.skill, :body, "DRIFTED"))
    assert {:error, :skill_not_pinned} = SkillLibrary.get_pinned(name)
    assert {:error, _} = SkillProvider.execute("prompt:" <> name, %{}, [])

    assert {:ok, %{builtin_versions: [%{state: "fallback"}]}} =
             SkillLibrary.version_manifest("absent", [])
  end

  test "raw whitespace and frontmatter are part of the approved adapter snapshot" do
    dir =
      Path.join(System.tmp_dir!(), "skill-source-version-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "SKILL.md")
    source = "---\nname: source-version\ndescription: Test source\n---\n\nBody\n"
    File.write!(path, source)
    {:ok, first} = SkillAdapter.parse(path)
    assert first.source_bytes == source
    :ok = SkillLibrary.register(first)
    {:ok, a} = SkillLibrary.prepare_approval(first.name)
    File.write!(path, source <> "\n")
    {:ok, second} = SkillAdapter.parse(path)
    assert second.body == first.body
    :ok = SkillLibrary.register(second)
    {:ok, b} = SkillLibrary.prepare_approval(first.name)
    refute a.digest == b.digest
  end

  test "malformed or oversized source and improper tool lists cannot become approvals", %{
    name: name
  } do
    {:ok, original} = SkillLibrary.get(name)

    for mutation <- [
          %{source_bytes: <<255>>},
          %{source_bytes: String.duplicate("x", 262_145)},
          %{allowed_tools: ["file_read" | :bad]}
        ] do
      :ok = SkillLibrary.register(Map.merge(original, mutation))
      assert {:error, :invalid_skill_version} = SkillLibrary.prepare_approval(name)
    end
  end
end
