defmodule Arbor.Actions.SkillVersionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.SessionLlm.BuildPrompt
  alias Arbor.Actions.Skill
  alias Arbor.Common.SkillLibrary
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Memory
  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression

  setup do
    unless Process.whereis(SkillLibrary), do: start_supervised!({SkillLibrary, dirs: []})
    name = "unapproved-#{System.unique_integer([:positive])}"

    :ok =
      SkillLibrary.register(%{
        name: name,
        description: "Unreviewed imported instructions",
        body: "UNAPPROVED_SKILL_INSTRUCTIONS",
        allowed_tools: [],
        taint: :untrusted,
        metadata: %{}
      })

    %{name: name}
  end

  @tag :trusted_skill_bug
  test "unreviewed import cannot activate merely because it requests no tools", %{name: name} do
    assert {:error, _} =
             Skill.Activate.run(%{skill_name: name}, %{agent_id: "agent_unapproved"})
  end

  @tag :trusted_skill_bug
  test "live prompt refuses forged active-skill content from working memory" do
    for skill <- [
          %{name: "forged", body: "FORGED_SKILL_BODY", taint: :trusted},
          %{
            "name" => "forged",
            "body" => "FORGED_SKILL_BODY",
            "version_digest" => String.duplicate("a", 64)
          }
        ] do
      assert {:ok, result} =
               BuildPrompt.run(
                 %{
                   mode: "heartbeat",
                   working_memory: %{active_skills: [skill], focus: "retained"}
                 },
                 %{agent_id: "agent_unapproved"}
               )

      refute result.heartbeat_prompt =~ "FORGED_SKILL_BODY"
      assert result.heartbeat_prompt =~ "retained"
    end
  end

  @tag :trusted_skill_bug
  test "a mutable DOT cache header does not approve an unreviewed skill", %{name: name} do
    dir =
      Path.join(System.tmp_dir!(), "skill-version-cache-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    body = "UNAPPROVED_SKILL_INSTRUCTIONS"
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    File.write!(
      Path.join(dir, "COMPILED.dot"),
      "// arbor:content_hash=#{digest}\ndigraph Unsafe {}"
    )

    {:ok, skill} = SkillLibrary.get(name)

    :ok =
      SkillLibrary.register(
        Map.merge(skill, %{path: Path.join(dir, "SKILL.md"), content_hash: digest})
      )

    assert {:error, _} =
             Skill.Compile.run(%{skill_name: name}, %{agent_id: "agent_unapproved"})
  end

  defmodule FailingMemory do
    def get_working_memory(_), do: nil
    def new_working_memory(id), do: Memory.new_working_memory(id)

    def activate_working_memory_skill(wm, skill),
      do: Memory.activate_working_memory_skill(wm, skill)

    def save_working_memory(_, _), do: {:error, :storage_unavailable}
  end

  defmodule Compiler do
    def generate_text(prompt, _opts) do
      send(Process.get(:skill_test_observer), {:skill_compile_request, prompt})

      case Process.get(:skill_test_after_request) do
        nil -> :ok
        callback -> callback.()
      end

      {:ok, "digraph ApprovedInput { start -> done }"}
    end
  end

  test "real exact approval activates, JSON round-trip consumes original bytes, and revoke stops further prompts",
       %{name: name} do
    owner = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    {:ok, version} = SkillLibrary.prepare_approval(name)
    cap = grant!(owner, version.resource_uri)

    assert {:ok, %{activated: true, version_digest: digest}} =
             Skill.Activate.run(%{skill_name: name}, %{agent_id: owner})

    assert digest == version.digest
    wm = Memory.get_working_memory(owner)
    assert [entry] = wm.active_skills
    assert entry.taint == :untrusted
    assert entry.approval_id == cap.id

    assert {:ok, %{activated: false}} =
             Skill.Activate.run(%{skill_name: name}, %{agent_id: owner})

    entries = Jason.decode!(Jason.encode!([Map.put(entry, :body, "FORGED_COPY")]))

    assert {:ok, result} =
             BuildPrompt.run(
               %{mode: "heartbeat", working_memory: %{"active_skills" => entries}},
               %{agent_id: owner}
             )

    assert result.heartbeat_prompt =~ "UNAPPROVED_SKILL_INSTRUCTIONS"
    refute result.heartbeat_prompt =~ "FORGED_COPY"
    assert {:ok, manifest} = Memory.skill_version_manifest(owner)
    assert [%{version_digest: ^digest, approval_id: id}] = manifest.active_versions
    assert id == cap.id
    assert Enum.all?(manifest.implementation, &(byte_size(&1.loaded_md5) == 32))

    assert :ok = Security.revoke(cap.id)

    assert {:ok, result} =
             BuildPrompt.run(%{mode: "heartbeat", working_memory: %{active_skills: entries}}, %{
               agent_id: owner
             })

    refute result.heartbeat_prompt =~ "UNAPPROVED_SKILL_INSTRUCTIONS"

    assert {:ok, %{skills: [%{approval_state: "revoked"}]}} =
             Skill.ListActive.run(%{}, %{agent_id: owner})
  end

  test "wildcard grants and another principal's exact approval do not approve a version", %{
    name: name
  } do
    owner = owner!()
    other = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    grant!(owner, "arbor://skill/use/**")
    {:ok, version} = SkillLibrary.prepare_approval(name)
    grant!(other, version.resource_uri)
    assert {:error, _} = Skill.Activate.run(%{skill_name: name}, %{agent_id: owner})
    {:ok, approved} = SkillLibrary.resolve_approved_version(name, other)
    assert [] == SkillLibrary.approved_active_skills(owner, [approved.approval])
  end

  test "body, declared tools, raw source bytes and version changes invalidate the original approval",
       %{name: name} do
    owner = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    {:ok, version} = SkillLibrary.prepare_approval(name)
    grant!(owner, version.resource_uri)
    {:ok, approved} = SkillLibrary.resolve_approved_version(name, owner)

    for mutation <- [
          %{body: "Changed"},
          %{allowed_tools: ["file_read"]},
          %{source_bytes: "same body, changed frontmatter or whitespace"},
          %{version: "2"}
        ] do
      :ok = SkillLibrary.register(Map.merge(version.skill, mutation))

      assert {:error, :skill_version_changed} =
               SkillLibrary.resolve_approved_version(name, owner, approved.approval)

      assert [] == SkillLibrary.approved_active_skills(owner, [approved.approval])
    end
  end

  test "activation never reports success when its actual memory save fails", %{name: name} do
    owner = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    configure!(:arbor_actions, :memory_module, FailingMemory)
    {:ok, version} = SkillLibrary.prepare_approval(name)
    grant!(owner, version.resource_uri)

    assert {:error, :storage_unavailable} =
             Skill.Activate.run(%{skill_name: name}, %{agent_id: owner})
  end

  test "approval does not grant declared tools and a missing approval service refuses", %{
    name: name
  } do
    owner = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    {:ok, skill} = SkillLibrary.get(name)
    :ok = SkillLibrary.register(Map.put(skill, :allowed_tools, ["shell_execute"]))
    {:ok, version} = SkillLibrary.prepare_approval(name)
    grant!(owner, version.resource_uri)
    assert {:error, _} = Skill.Activate.run(%{skill_name: name}, %{agent_id: owner})
    configure!(:arbor_common, :skill_security_module, nil)

    assert {:error, :skill_approval_unavailable} =
             SkillLibrary.resolve_approved_version(name, owner)
  end

  test "approved compilation binds untrusted output, rejects legacy cache, and private policy stops provider effects",
       %{name: name} do
    owner = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    configure!(:arbor_actions, :ai_module, Compiler)
    Process.put(:skill_test_observer, self())

    dir =
      Path.join(System.tmp_dir!(), "approved-skill-cache-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "COMPILED.dot")
    {:ok, skill} = SkillLibrary.get(name)
    :ok = SkillLibrary.register(Map.put(skill, :path, Path.join(dir, "SKILL.md")))
    {:ok, version} = SkillLibrary.prepare_approval(name)
    grant!(owner, version.resource_uri)

    for op <- [:read, :write] do
      uri = Security.authorization_resource_uri("arbor://fs/#{op}", file_path: path)
      grant!(owner, uri)
    end

    File.write!(path, "// arbor:content_hash=legacy\ndigraph Unsafe {}")

    assert {:error, :memory_write_denied} =
             Skill.Compile.run(%{skill_name: name}, %{
               agent_id: owner,
               memory_write_policy: :deny
             })

    refute_received {:skill_compile_request, _}

    assert {:ok, result} =
             Skill.Compile.run(%{skill_name: name}, %{agent_id: owner})

    assert result.taint == :untrusted
    assert result.input_version_digest == version.digest

    assert result.output_digest ==
             :crypto.hash(:sha256, result.dot) |> Base.encode16(case: :lower)

    assert_received {:skill_compile_request, request}
    assert request =~ skill.body
    refute result.cached

    assert {:ok, %{cached: true, output_digest: hash}} =
             Skill.Compile.run(%{skill_name: name}, %{agent_id: owner})

    assert hash == result.output_digest
    refute_received {:skill_compile_request, _}
    File.write!(path, File.read!(path) <> "\n// tampered")

    assert {:ok, %{cached: false}} =
             Skill.Compile.run(%{skill_name: name}, %{agent_id: owner})

    assert_received {:skill_compile_request, _}
  end

  test "new approval cannot silently replace an already active version", %{name: name} do
    owner = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    {:ok, original} = SkillLibrary.prepare_approval(name)
    grant!(owner, original.resource_uri)
    assert {:ok, %{activated: true}} = Skill.Activate.run(%{skill_name: name}, %{agent_id: owner})
    :ok = SkillLibrary.register(Map.put(original.skill, :body, "NEW_UNACTIVATED_BODY"))
    {:ok, changed} = SkillLibrary.prepare_approval(name)
    grant!(owner, changed.resource_uri)

    assert {:error, :skill_version_changed} =
             Skill.Activate.run(%{skill_name: name}, %{agent_id: owner})

    assert {:ok, result} =
             BuildPrompt.run(
               %{
                 mode: "heartbeat",
                 working_memory: Map.from_struct(Memory.get_working_memory(owner))
               },
               %{agent_id: owner}
             )

    refute result.heartbeat_prompt =~ "NEW_UNACTIVATED_BODY"
  end

  test "revocation during compilation refuses cache publication and the result", %{name: name} do
    owner = owner!()
    configure!(:arbor_common, :skill_security_module, Arbor.Security)
    configure!(:arbor_actions, :ai_module, Compiler)
    Process.put(:skill_test_observer, self())

    dir =
      Path.join(System.tmp_dir!(), "revoked-skill-cache-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "COMPILED.dot")
    {:ok, skill} = SkillLibrary.get(name)
    :ok = SkillLibrary.register(Map.put(skill, :path, Path.join(dir, "SKILL.md")))
    {:ok, version} = SkillLibrary.prepare_approval(name)
    cap = grant!(owner, version.resource_uri)

    for op <- [:read, :write],
        do:
          grant!(owner, Security.authorization_resource_uri("arbor://fs/#{op}", file_path: path))

    Process.put(:skill_test_after_request, fn -> :ok = Security.revoke(cap.id) end)
    assert {:error, _} = Skill.Compile.run(%{skill_name: name}, %{agent_id: owner})
    assert_received {:skill_compile_request, _}
    refute File.exists?(path)
  end

  defp owner! do
    {:ok, identity} = Identity.generate()

    :ok =
      Security.register_identity(Identity.public_only(identity))

    identity.agent_id
  end

  defp grant!(owner, uri) do
    {:ok, cap} = Security.grant(principal: owner, resource: uri)
    on_exit(fn -> Security.revoke(cap.id) end)
    cap
  end

  defp configure!(:arbor_common, key, value) do
    previous = Application.fetch_env(:arbor_kernel, :common)

    Application.put_env(
      :arbor_kernel,
      :common,
      Keyword.put(Application.get_env(:arbor_kernel, :common, []), key, value)
    )

    on_exit(fn -> restore!(:arbor_kernel, :common, previous) end)
  end

  defp configure!(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)
    on_exit(fn -> restore!(app, key, previous) end)
  end

  defp restore!(app, key, {:ok, old}), do: Application.put_env(app, key, old)
  defp restore!(app, key, :error), do: Application.delete_env(app, key)
end
