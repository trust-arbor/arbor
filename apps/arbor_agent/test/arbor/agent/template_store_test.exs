defmodule Arbor.Agent.TemplateStoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.{Character, Template, TemplateStore}

  @test_dir Path.join(System.tmp_dir!(), "arbor_template_store_test_#{System.unique_integer([:positive])}")

  setup do
    # Use a temp directory for tests
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    TemplateStore.set_templates_dir(@test_dir)

    # Clear ETS if it exists
    if :ets.whereis(:arbor_agent_templates) != :undefined do
      :ets.delete_all_objects(:arbor_agent_templates)
    end

    on_exit(fn ->
      TemplateStore.clear_templates_dir_override()
      File.rm_rf!(@test_dir)

      if :ets.whereis(:arbor_agent_templates) != :undefined do
        :ets.delete_all_objects(:arbor_agent_templates)
      end
    end)

    :ok
  end

  describe "CRUD operations" do
    test "put and get a template" do
      data = minimal_template("test_agent")
      assert :ok = TemplateStore.put("test_agent", data)
      assert {:ok, loaded} = TemplateStore.get("test_agent")
      assert loaded["name"] == "test_agent"
      assert loaded["trust_tier"] == "probationary"
    end

    test "get returns not_found for missing template" do
      assert {:error, :not_found} = TemplateStore.get("nonexistent")
    end

    test "list returns all templates" do
      TemplateStore.put("alpha", minimal_template("alpha"))
      TemplateStore.put("beta", minimal_template("beta"))
      templates = TemplateStore.list()
      names = Enum.map(templates, & &1["name"])
      assert "alpha" in names
      assert "beta" in names
    end

    test "exists? returns true for existing template" do
      TemplateStore.put("exists_test", minimal_template("exists_test"))
      assert TemplateStore.exists?("exists_test")
      refute TemplateStore.exists?("does_not_exist")
    end

    test "delete removes a user template" do
      TemplateStore.put("deletable", minimal_template("deletable"))
      assert TemplateStore.exists?("deletable")
      assert :ok = TemplateStore.delete("deletable")
      refute TemplateStore.exists?("deletable")
    end

    test "delete refuses to delete builtin templates" do
      assert {:error, :builtin_protected} = TemplateStore.delete("scout")
    end

    test "update merges changes and bumps version" do
      TemplateStore.put("updatable", minimal_template("updatable"))
      assert :ok = TemplateStore.update("updatable", %{"description" => "Updated!"})
      {:ok, updated} = TemplateStore.get("updatable")
      assert updated["description"] == "Updated!"
      assert updated["version"] == 2
      assert updated["updated_at"] != nil
    end

    test "update returns error for missing template" do
      assert {:error, :not_found} = TemplateStore.update("missing", %{"description" => "x"})
    end
  end

  describe "from_module/1" do
    @builtin_modules [
      Arbor.Agent.Templates.Scout,
      Arbor.Agent.Templates.Researcher,
      Arbor.Agent.Templates.CodeReviewer,
      Arbor.Agent.Templates.Monitor,
      Arbor.Agent.Templates.Diagnostician,
      Arbor.Agent.Templates.Conversationalist
    ]

    for mod <- @builtin_modules do
      test "converts #{mod |> Module.split() |> List.last()} correctly" do
        module = unquote(mod)
        data = TemplateStore.from_module(module)

        assert is_binary(data["name"])
        assert data["version"] == 1
        assert data["source"] == "builtin"
        assert is_map(data["character"])
        assert is_binary(data["character"]["name"])
        assert is_binary(data["trust_tier"])
        assert is_list(data["initial_goals"])
        assert is_list(data["required_capabilities"])
        assert is_binary(data["created_at"])
      end
    end

    test "character fields are string-keyed" do
      data = TemplateStore.from_module(Arbor.Agent.Templates.Scout)
      char = data["character"]
      assert Map.has_key?(char, "name")
      assert Map.has_key?(char, "traits")
      refute Map.has_key?(char, :name)
    end

    test "goals and capabilities have string keys" do
      data = TemplateStore.from_module(Arbor.Agent.Templates.Scout)

      for goal <- data["initial_goals"] do
        assert Enum.all?(Map.keys(goal), &is_binary/1)
      end

      for cap <- data["required_capabilities"] do
        assert Enum.all?(Map.keys(cap), &is_binary/1)
      end
    end
  end

  describe "to_keyword/1" do
    test "round-trips from module through data and back" do
      module = Arbor.Agent.Templates.Scout
      original = Template.apply(module)
      data = TemplateStore.from_module(module)
      restored = TemplateStore.to_keyword(data)

      # Character struct should match
      assert %Character{} = restored[:character]
      assert restored[:character].name == original[:character].name
      assert restored[:character].tone == original[:character].tone

      # Scalar fields
      assert restored[:trust_tier] == original[:trust_tier]
      assert restored[:name] == original[:name]
      assert restored[:nature] == original[:nature]
      assert restored[:domain_context] == original[:domain_context]

      # List fields
      assert restored[:values] == original[:values]
      assert restored[:initial_thoughts] == original[:initial_thoughts]

      # Meta-awareness
      assert restored[:meta_awareness][:grown_from_template] == true
    end

    test "handles minimal data" do
      data = %{"name" => "minimal", "character" => %{"name" => "Minimal"}}
      kw = TemplateStore.to_keyword(data)
      assert kw[:name] == "Minimal"
      assert kw[:trust_tier] == :untrusted
      assert kw[:initial_goals] == []
    end
  end

  describe "name mapping" do
    test "module_to_name maps builtins correctly" do
      assert TemplateStore.module_to_name(Arbor.Agent.Templates.Scout) == "scout"
      assert TemplateStore.module_to_name(Arbor.Agent.Templates.Diagnostician) == "diagnostician"
      assert TemplateStore.module_to_name(Arbor.Agent.Templates.Conversationalist) == "conversationalist"
      assert TemplateStore.module_to_name(Arbor.Agent.Templates.CodeReviewer) == "code_reviewer"
    end

    test "module_to_name derives name for unknown modules" do
      assert TemplateStore.module_to_name(Some.Custom.Template) == "template"
    end

    test "name_to_module returns module for builtins" do
      assert TemplateStore.name_to_module("scout") == Arbor.Agent.Templates.Scout
      assert TemplateStore.name_to_module("diagnostician") == Arbor.Agent.Templates.Diagnostician
    end

    test "name_to_module returns nil for unknown names" do
      assert TemplateStore.name_to_module("custom_agent") == nil
    end

    test "normalize_ref handles all types" do
      assert TemplateStore.normalize_ref(nil) == nil
      assert TemplateStore.normalize_ref("scout") == "scout"
      assert TemplateStore.normalize_ref(Arbor.Agent.Templates.Scout) == "scout"
    end
  end

  describe "resolve/1" do
    test "resolves by string name after put" do
      TemplateStore.put("my_agent", minimal_template("my_agent"))
      assert {:ok, data} = TemplateStore.resolve("my_agent")
      assert data["name"] == "my_agent"
    end

    test "resolves by module atom" do
      # Seed first so the file exists
      data = TemplateStore.from_module(Arbor.Agent.Templates.Scout)
      TemplateStore.put("scout", data)

      assert {:ok, resolved} = TemplateStore.resolve(Arbor.Agent.Templates.Scout)
      assert resolved["name"] == "scout"
    end

    test "resolves module by falling back to direct module call" do
      # Don't seed — should fall back to loading from module
      assert {:ok, resolved} = TemplateStore.resolve(Arbor.Agent.Templates.Scout)
      assert resolved["name"] == "scout"
      assert resolved["source"] == "builtin"
    end

    test "returns not_found for unknown" do
      assert {:error, :not_found} = TemplateStore.resolve("totally_unknown")
    end
  end

  describe "seed_builtins/0" do
    test "seeds builtin templates and is idempotent" do
      # First seed creates files
      {:ok, first_count} = TemplateStore.seed_builtins()
      # At least 6 (CliAgent module may not exist yet until rename)
      assert first_count >= 6

      # Verify they're loadable
      for name <- ["scout", "researcher", "code_reviewer", "monitor", "diagnostician", "conversationalist"] do
        assert {:ok, _} = TemplateStore.get(name)
      end

      # Second seed should create 0 (idempotent)
      {:ok, second_count} = TemplateStore.seed_builtins()
      assert second_count == 0
    end
  end

  describe "create_from_opts/2" do
    test "creates a template from keyword opts" do
      assert :ok =
               TemplateStore.create_from_opts("custom", [
                 character: %{name: "Custom Agent"},
                 trust_tier: :probationary,
                 initial_goals: [%{type: :explore, description: "Explore"}],
                 required_capabilities: [%{resource: "arbor://fs/read/**"}],
                 description: "A custom agent"
               ])

      assert {:ok, data} = TemplateStore.get("custom")
      assert data["name"] == "custom"
      assert data["source"] == "user"
      assert data["trust_tier"] == "probationary"
      assert data["description"] == "A custom agent"
    end

    test "creates a template from Character struct" do
      char = Arbor.Agent.Character.new(name: "Structured", role: "Tester")

      assert :ok = TemplateStore.create_from_opts("structured", character: char)
      assert {:ok, data} = TemplateStore.get("structured")
      assert data["character"]["name"] == "Structured"
      assert data["character"]["role"] == "Tester"
    end
  end

  describe "reload/0" do
    test "picks up manually written files" do
      # Write a file directly (simulating manual edit)
      dir = TemplateStore.templates_dir()
      File.mkdir_p!(dir)
      data = minimal_template("manual_edit")
      File.write!(Path.join(dir, "manual_edit.json"), Jason.encode!(data))

      # Should find it after reload
      TemplateStore.reload()
      assert {:ok, loaded} = TemplateStore.get("manual_edit")
      assert loaded["name"] == "manual_edit"
    end
  end

  describe "builtin_names/0" do
    test "returns all builtin names" do
      names = TemplateStore.builtin_names()
      assert "scout" in names
      assert "diagnostician" in names
      assert "cli_agent" in names
      assert length(names) == 7
    end
  end

  # --- Helpers ---

  defp minimal_template(name) do
    %{
      "name" => name,
      "version" => 1,
      "source" => "user",
      "character" => %{"name" => String.capitalize(name)},
      "trust_tier" => "probationary",
      "initial_goals" => [],
      "required_capabilities" => [],
      "description" => "",
      "nature" => "",
      "values" => [],
      "initial_interests" => [],
      "initial_thoughts" => [],
      "relationship_style" => %{},
      "domain_context" => "",
      "metadata" => %{},
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end
end
