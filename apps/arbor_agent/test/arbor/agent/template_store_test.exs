defmodule Arbor.Agent.TemplateStoreTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.{Character, TemplateStore}
  alias Arbor.Agent.Template.File, as: TemplateFile

  @test_dir Path.join(
              System.tmp_dir!(),
              "arbor_template_store_test_#{System.unique_integer([:positive])}"
            )

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

  describe "shipped builtin .md files" do
    # Post-B2: shipped `.md` files in priv/templates/ are the source of truth.
    # Each one must resolve, parse, validate, and produce a well-formed data map.
    for name <- TemplateStore.builtin_names() do
      test "resolves and validates shipped #{name}" do
        name = unquote(name)
        assert {:ok, data} = TemplateStore.resolve(name)

        assert data["name"] == name
        assert is_map(data["character"])
        assert is_binary(data["character"]["name"])
        assert is_list(data["initial_goals"])
        assert is_list(data["required_capabilities"])
        assert :ok = TemplateFile.validate(data)

        # character + goals + caps are string-keyed (JSON-clean for the context boundary).
        char = data["character"]
        assert Map.has_key?(char, "name")
        refute Map.has_key?(char, :name)

        for goal <- data["initial_goals"], do: assert(Enum.all?(Map.keys(goal), &is_binary/1))

        for cap <- data["required_capabilities"],
            do: assert(Enum.all?(Map.keys(cap), &is_binary/1))
      end
    end
  end

  describe "to_keyword/1" do
    test "converts a resolved shipped template to a Lifecycle keyword list" do
      {:ok, data} = TemplateStore.resolve("scout")
      restored = TemplateStore.to_keyword(data)

      assert %Character{} = restored[:character]
      assert restored[:character].name == data["character"]["name"]
      assert restored[:nature] == data["nature"]
      assert restored[:domain_context] == data["domain_context"]
      assert restored[:values] == data["values"]
      assert restored[:initial_thoughts] == data["initial_thoughts"]

      # Meta-awareness + provenance (template_source attached by resolve/1).
      assert restored[:meta_awareness][:grown_from_template] == true
      assert restored[:meta_awareness][:template_source]["layer"] in ~w(user shipped legacy_json)
    end

    test "handles minimal data" do
      data = %{"name" => "minimal", "character" => %{"name" => "Minimal"}}
      kw = TemplateStore.to_keyword(data)
      assert kw[:name] == "Minimal"
      assert kw[:initial_goals] == []
    end
  end

  describe "name mapping" do
    # Post-B2: module_to_name/1 inflects the last module segment (no builtin map);
    # the per-persona modules no longer exist, so this is purely a back-compat
    # convenience for stray atom callers.
    test "module_to_name inflects the last module segment" do
      assert TemplateStore.module_to_name(Some.Custom.Scout) == "scout"
      assert TemplateStore.module_to_name(Some.Custom.CodeReviewer) == "code_reviewer"
      assert TemplateStore.module_to_name(Some.Custom.Template) == "template"
    end

    test "normalize_ref handles all types" do
      assert TemplateStore.normalize_ref(nil) == nil
      assert TemplateStore.normalize_ref("scout") == "scout"
      assert TemplateStore.normalize_ref(Some.Custom.Scout) == "scout"
    end
  end

  describe "resolve/1" do
    test "resolves by string name after put" do
      TemplateStore.put("my_agent", minimal_template("my_agent"))
      assert {:ok, data} = TemplateStore.resolve("my_agent")
      assert data["name"] == "my_agent"
    end

    test "resolves a stray atom by inflecting to the shipped .md name" do
      # No module exists; the atom clause inflects "Scout" -> "scout" and
      # resolves the shipped scout.md file.
      assert {:ok, resolved} = TemplateStore.resolve(Some.Stray.Scout)
      assert resolved["name"] == "scout"
      assert resolved["template_source"]["layer"] in ~w(user shipped legacy_json)
    end

    test "resolves a builtin by string name from the shipped .md" do
      assert {:ok, resolved} = TemplateStore.resolve("scout")
      assert resolved["name"] == "scout"
    end

    test "returns not_found for unknown" do
      assert {:error, :not_found} = TemplateStore.resolve("totally_unknown")
    end
  end

  describe "resolve (data-first, shipped .md is the source of truth)" do
    @expected_builtins ~w(
      api_agent blog_agent cli_agent code_reviewer coding_agent conversationalist
      council_evaluator diagnostician interview_agent monitor pipeline_architect researcher scout
      security_auditor test_agent
    )

    test "builtin_names/0 lists exactly the 15 expected builtins" do
      assert Enum.sort(TemplateStore.builtin_names()) == Enum.sort(@expected_builtins)
    end

    test "every expected builtin resolves from a shipped .md and validates" do
      for name <- @expected_builtins do
        assert {:ok, data} = TemplateStore.resolve(name), "expected #{name} to resolve"
        assert :ok = Arbor.Agent.Template.File.validate(data)
        assert data["template_source"]["layer"] in ~w(user shipped legacy_json)
      end
    end

    test "user .md overrides shipped .md (highest precedence)" do
      # Write a user-layer override for an existing builtin into the tmp dir
      # (which the override makes the user/legacy dir).
      dir = TemplateStore.user_templates_dir()
      File.mkdir_p!(dir)

      {:ok, shipped} = TemplateStore.resolve("scout")
      data = Map.put(shipped, "description", "USER OVERRIDE")

      md = Arbor.Agent.Template.File.serialize(data)
      File.write!(Path.join(dir, "scout.md"), md)

      # Clear any cached entry so resolve re-reads from disk.
      TemplateStore.ensure_table()
      :ets.delete(:arbor_agent_templates, "scout")

      assert {:ok, resolved} = TemplateStore.resolve("scout")
      assert resolved["description"] == "USER OVERRIDE"
      assert resolved["template_source"]["layer"] == "user"
    end

    test "legacy .json fallback still resolves when no .md exists" do
      # Write a legacy JSON template into the (overridden) legacy dir under a
      # name that has no shipped .md, and confirm it resolves via the json layer.
      dir = TemplateStore.templates_dir()
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "legacy_only.json"),
        Jason.encode!(minimal_template("legacy_only"))
      )

      TemplateStore.ensure_table()
      :ets.delete(:arbor_agent_templates, "legacy_only")

      assert {:ok, resolved} = TemplateStore.resolve("legacy_only")
      assert resolved["name"] == "legacy_only"
      assert resolved["template_source"]["layer"] == "legacy_json"
    end
  end

  describe "create_from_opts/2" do
    test "creates a template from keyword opts" do
      assert :ok =
               TemplateStore.create_from_opts("custom",
                 character: %{name: "Custom Agent"},
                 initial_goals: [%{type: :explore, description: "Explore"}],
                 required_capabilities: [%{resource: "arbor://fs/read/**"}],
                 description: "A custom agent"
               )

      assert {:ok, data} = TemplateStore.get("custom")
      assert data["name"] == "custom"
      assert data["source"] == "user"
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
      assert "api_agent" in names
      assert "coding_agent" in names
      assert "pipeline_architect" in names
      assert length(names) == 15
    end
  end

  describe "coding_agent template" do
    test "delegates implementation to Codex via ACP and keeps human review gates" do
      assert {:ok, data} = TemplateStore.resolve("coding_agent")

      assert data["metadata"]["runtime"] == "acp"
      assert data["metadata"]["acp_provider"] == "codex"

      resources = Enum.map(data["required_capabilities"], & &1["resource"])
      assert "arbor://action/coding/produce_reviewable_change" in resources
      assert "arbor://action/coding/security_regression/validate" in resources
      assert "arbor://action/coding/cross_app/validate" in resources
      assert "arbor://action/coding/workspace/**" in resources
      assert "arbor://acp/tool" in resources
      assert "arbor://action/git/**" in resources
      assert "arbor://action/mix/**" in resources
      assert "arbor://action/council/review" in resources
      refute "arbor://shell/exec/git" in resources
      refute "arbor://shell/exec/mix" in resources
      refute "arbor://action/github/pr" in resources

      preset = data["trust_preset"]
      assert preset["baseline"] == "block"
      assert preset["rules"]["arbor://orchestrator/execute"] == "auto"
      assert preset["rules"]["arbor://action/coding/produce_reviewable_change"] == "auto"
      assert preset["rules"]["arbor://action/coding/security_regression/validate"] == "ask"
      assert preset["rules"]["arbor://action/coding/cross_app/validate"] == "ask"
      assert preset["rules"]["arbor://action/coding/workspace"] == "auto"
      assert preset["rules"]["arbor://action/git"] == "auto"
      assert preset["rules"]["arbor://action/mix"] == "auto"
      assert preset["rules"]["arbor://shell/exec"] == "ask"
      assert preset["rules"]["arbor://action/council/review"] == "auto"
      refute Map.has_key?(preset["rules"], "arbor://shell/exec/git")
      refute Map.has_key?(preset["rules"], "arbor://shell/exec/mix")
      refute Map.has_key?(preset["rules"], "arbor://action/github/pr")

      trust_rules =
        preset["rules"]
        |> Map.new(fn {uri, mode} ->
          normalized = %{"auto" => :auto, "ask" => :ask, "allow" => :allow, "block" => :block}
          {uri, Map.fetch!(normalized, mode)}
        end)
        |> Map.put("arbor://action/coding", :auto)

      assert Arbor.Trust.ProfileResolver.resolve_prefix(
               trust_rules,
               "arbor://action/coding/security_regression/validate",
               :block
             ) == :ask

      refute Map.has_key?(preset["rules"], "arbor://trust/write")
    end

    test "shipped instructions treat structured coding_change as canonical and composite as rollback" do
      assert {:ok, data} = TemplateStore.resolve("coding_agent")
      instructions = data["character"]["instructions"]
      joined = Enum.join(instructions, "\n")

      assert Enum.any?(
               instructions,
               &String.contains?(&1, "Structured `coding_change` dispatch is the canonical")
             )

      assert joined =~ "compile and execute"
      assert joined =~ "DOT pipeline"
      assert joined =~ ~s({"kind":"coding_change","plan":{...}})
      assert joined =~ "worker.provider"

      assert Enum.any?(
               instructions,
               &String.contains?(&1, "coding_produce_reviewable_change")
             )

      assert joined =~ "compatibility/rollback"
      assert joined =~ "one release window"
      assert joined =~ "Do not nest `coding_produce_reviewable_change`"

      # Stale primary-macro framing must not remain
      refute Enum.any?(
               instructions,
               &String.contains?(
                 &1,
                 "Use `coding_produce_reviewable_change` for implementation tasks"
               )
             )

      # Rollback capability/trust entries stay for the legacy window
      resources = Enum.map(data["required_capabilities"], & &1["resource"])
      assert "arbor://action/coding/produce_reviewable_change" in resources

      assert data["trust_preset"]["rules"]["arbor://action/coding/produce_reviewable_change"] ==
               "auto"
    end
  end

  describe "pipeline_architect template" do
    test "declares the exact read-only runtime, sandbox, tools, and capabilities" do
      assert {:ok, data} = TemplateStore.resolve("pipeline_architect")

      assert data["sandbox_level"] == "strict"

      assert Map.take(data["metadata"], [
               "capability_policy",
               "runtime",
               "runtime_policy",
               "sandbox_policy",
               "tool_policy",
               "trust_preset_policy",
               "tools"
             ]) == %{
               "capability_policy" => "exact",
               "runtime" => "arbor",
               "runtime_policy" => "exact",
               "sandbox_policy" => "exact",
               "tool_policy" => "exact",
               "trust_preset_policy" => "exact",
               "tools" => ~w(file_read file_list file_search file_exists)
             }

      resources =
        data["required_capabilities"]
        |> Enum.map(& &1["resource"])
        |> Enum.sort()

      assert resources ==
               Enum.sort([
                 "arbor://orchestrator/execute",
                 "arbor://fs/read/repo",
                 "arbor://fs/list/repo"
               ])

      refute Enum.any?(resources, fn resource ->
               String.contains?(resource, [
                 "write",
                 "shell",
                 "acp",
                 "dispatch",
                 "pipeline/run"
               ])
             end)
    end

    test "uses a baseline:block allowlist with explicit execution-authority blocks" do
      assert {:ok, data} = TemplateStore.resolve("pipeline_architect")
      preset = data["trust_preset"]
      rules = preset["rules"]

      assert preset["baseline"] == "block"
      assert rules["arbor://orchestrator/execute"] == "allow"
      assert rules["arbor://fs/read"] == "allow"
      assert rules["arbor://fs/list"] == "allow"

      blocked = [
        "arbor://orchestrator/execute/adapt",
        "arbor://orchestrator/execute/compose",
        "arbor://orchestrator/execute/file_write",
        "arbor://orchestrator/execute/graph_mutation",
        "arbor://orchestrator/execute/map",
        "arbor://orchestrator/execute/shell_exec",
        "arbor://orchestrator/map/dispatch",
        "arbor://fs",
        "arbor://fs/write",
        "arbor://fs/execute",
        "arbor://fs/delete",
        "arbor://shell",
        "arbor://acp",
        "arbor://agent",
        "arbor://agent/dispatch",
        "arbor://agent/task",
        "arbor://agent/spawn",
        "arbor://agent/spawn_worker",
        "arbor://agent/lifecycle",
        "arbor://trust",
        "arbor://trust/write",
        "arbor://trust/auto_promote",
        "arbor://governance",
        "arbor://action",
        "arbor://action/coding",
        "arbor://action/pipeline/run",
        "arbor://pipeline",
        "arbor://pipeline/run",
        "arbor://code",
        "arbor://code/write",
        "arbor://code/compile",
        "arbor://code/hot_load",
        "arbor://sandbox"
      ]

      for uri <- blocked do
        assert rules[uri] == "block", "expected #{uri} to be explicitly blocked"
      end

      assert map_size(rules) == length(blocked) + 3
    end

    test "requires strict CodingPlan v1 output and keeps raw DOT proposal-only" do
      assert {:ok, data} = TemplateStore.resolve("pipeline_architect")
      instructions = data["character"]["instructions"]

      assert data["domain_context"] =~ "CodingPlan v1 is a closed object"
      assert data["domain_context"] =~ "A separate caller-bound executor"
      assert Enum.any?(instructions, &String.contains?(&1, "strict CodingPlan v1 object"))
      assert Enum.any?(instructions, &String.contains?(&1, "NON-EXECUTABLE PROPOSAL"))
      assert Enum.any?(instructions, &String.contains?(&1, "never run, validate, compile"))
    end
  end

  # --- Helpers ---

  defp minimal_template(name) do
    %{
      "name" => name,
      "version" => 1,
      "source" => "user",
      "character" => %{"name" => String.capitalize(name)},
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
