defmodule Arbor.Common.SkillLibraryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SkillLibrary
  alias Arbor.Contracts.Skill

  @fixtures_dir Path.expand("../../fixtures/skills", __DIR__)

  # We need a unique table name per test run to avoid conflicts.
  # The SkillLibrary uses a named ETS table, so we start/stop it per test.

  setup do
    # Ensure the GenServer is not running from a previous test
    if Process.whereis(SkillLibrary) do
      GenServer.stop(SkillLibrary)
      # Brief pause to ensure cleanup
      Process.sleep(10)
    end

    # Clean up the ETS table if it exists from a previous run
    if :ets.whereis(:arbor_skill_library) != :undefined do
      :ets.delete(:arbor_skill_library)
    end

    :ok
  end

  describe "start_link/1 and init" do
    test "starts the GenServer and creates ETS table" do
      assert {:ok, pid} = SkillLibrary.start_link(dirs: [])
      assert Process.alive?(pid)
      assert :ets.whereis(:arbor_skill_library) != :undefined

      GenServer.stop(pid)
    end

    test "accepts custom dirs option" do
      assert {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert Process.alive?(pid)

      # Give it a moment to process the async scan_dirs message
      Process.sleep(50)

      # Should have indexed some skills
      assert SkillLibrary.count() > 0

      GenServer.stop(pid)
    end
  end

  describe "get/1" do
    test "returns skill when found in ETS" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      assert {:ok, skill} = SkillLibrary.get("security-perspective")
      assert Map.get(skill, :name) == "security-perspective"
      assert Map.get(skill, :source) == :skill

      GenServer.stop(pid)
    end

    test "returns error when skill not found" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      assert {:error, :not_found} = SkillLibrary.get("nonexistent-skill")

      GenServer.stop(pid)
    end

    test "returns error when ETS table does not exist" do
      # Don't start the GenServer - table shouldn't exist
      assert {:error, :not_found} = SkillLibrary.get("anything")
    end
  end

  describe "list/1" do
    test "returns all skills when no filters" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      skills = SkillLibrary.list()
      assert is_list(skills)
      assert skills != []

      GenServer.stop(pid)
    end

    test "filters by category" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      advisory_skills = SkillLibrary.list(category: "advisory")
      assert is_list(advisory_skills)
      assert Enum.all?(advisory_skills, &(Map.get(&1, :category) == "advisory"))

      GenServer.stop(pid)
    end

    test "filters by tags" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      tagged_skills = SkillLibrary.list(tags: ["security"])
      assert is_list(tagged_skills)

      assert Enum.all?(tagged_skills, fn skill ->
               tags = Map.get(skill, :tags) || []
               "security" in tags
             end)

      GenServer.stop(pid)
    end

    test "filters by source" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      fabric_skills = SkillLibrary.list(source: :fabric)
      assert is_list(fabric_skills)
      assert Enum.all?(fabric_skills, &(Map.get(&1, :source) == :fabric))

      GenServer.stop(pid)
    end

    test "returns empty list when no skills match filter" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      result = SkillLibrary.list(category: "nonexistent-category")
      assert result == []

      GenServer.stop(pid)
    end

    test "returns empty list when ETS table does not exist" do
      skills = SkillLibrary.list()
      assert skills == []
    end
  end

  describe "search/2" do
    test "finds skills matching query in name" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      results = SkillLibrary.search("security")
      assert is_list(results)
      assert results != []

      # Security perspective should be in results (matches name)
      names = Enum.map(results, &Map.get(&1, :name))
      assert "security-perspective" in names

      GenServer.stop(pid)
    end

    test "finds skills matching query in description" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      results = SkillLibrary.search("defensive")
      assert is_list(results)
      assert results != []

      GenServer.stop(pid)
    end

    test "returns empty list for no matches" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      results = SkillLibrary.search("zzzznonexistentzzzz")
      assert results == []

      GenServer.stop(pid)
    end

    test "respects limit option" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      # Search for something broad that matches multiple skills
      results = SkillLibrary.search("a", limit: 1)
      assert length(results) <= 1

      GenServer.stop(pid)
    end

    test "respects category filter" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      results = SkillLibrary.search("overview", category: "advisory")
      assert is_list(results)
      assert Enum.all?(results, &(Map.get(&1, :category) == "advisory"))

      GenServer.stop(pid)
    end
  end

  describe "register/1" do
    test "registers a skill in the library" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      {:ok, skill} =
        Skill.new(%{
          name: "test-skill",
          description: "A test skill for testing",
          body: "Test body content",
          tags: ["testing"],
          category: "test",
          source: :skill
        })

      assert :ok = SkillLibrary.register(skill)
      assert {:ok, retrieved} = SkillLibrary.get("test-skill")
      assert Map.get(retrieved, :name) == "test-skill"

      GenServer.stop(pid)
    end

    test "returns error for skill without a name" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      # A plain map with no name field
      assert {:error, {:invalid_skill, _}} = SkillLibrary.register(%{name: nil})
      assert {:error, {:invalid_skill, _}} = SkillLibrary.register(%{name: ""})

      GenServer.stop(pid)
    end
  end

  describe "index/2" do
    test "indexes skills from a directory" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      assert {:ok, count} = SkillLibrary.index(@fixtures_dir)
      assert count > 0

      GenServer.stop(pid)
    end

    test "returns error for non-directory path" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      assert {:error, {:not_a_directory, _}} =
               SkillLibrary.index("/nonexistent/path/that/does/not/exist")

      GenServer.stop(pid)
    end

    test "does not overwrite existing skills by default" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      # Index once
      {:ok, first_count} = SkillLibrary.index(@fixtures_dir)
      assert first_count > 0

      # Index again - should not add duplicates
      {:ok, second_count} = SkillLibrary.index(@fixtures_dir)
      assert second_count == 0

      GenServer.stop(pid)
    end

    test "overwrites existing skills when option set" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      # Index once
      {:ok, first_count} = SkillLibrary.index(@fixtures_dir)
      assert first_count > 0

      # Index again with overwrite
      {:ok, second_count} = SkillLibrary.index(@fixtures_dir, overwrite: true)
      assert second_count == first_count

      GenServer.stop(pid)
    end
  end

  describe "count/0" do
    test "returns 0 when ETS table does not exist" do
      assert SkillLibrary.count() == 0
    end

    test "returns correct count after indexing" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      count = SkillLibrary.count()
      assert count > 0

      GenServer.stop(pid)
    end
  end

  describe "reload/0" do
    test "clears and re-indexes all skills" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      Process.sleep(50)

      initial_count = SkillLibrary.count()
      assert initial_count > 0

      # Reload should clear and re-scan
      assert :ok = SkillLibrary.reload()

      # Count should be approximately the same after reload
      new_count = SkillLibrary.count()
      assert new_count > 0

      GenServer.stop(pid)
    end
  end

  describe "relevance_score/2" do
    test "scores higher for name matches" do
      skill = %{name: "security", description: "other", body: "other", tags: []}
      assert SkillLibrary.relevance_score(skill, "security") >= 4
    end

    test "scores for description matches" do
      skill = %{name: "other", description: "security review", body: "other", tags: []}
      score = SkillLibrary.relevance_score(skill, "security")
      assert score >= 3
    end

    test "scores for tag matches" do
      skill = %{name: "other", description: "other", body: "other", tags: ["security"]}
      score = SkillLibrary.relevance_score(skill, "security")
      assert score >= 2
    end

    test "scores for body matches" do
      skill = %{name: "other", description: "other", body: "security analysis", tags: []}
      score = SkillLibrary.relevance_score(skill, "security")
      assert score >= 1
    end

    test "returns 0 for no matches" do
      skill = %{name: "foo", description: "bar", body: "baz", tags: ["qux"]}
      assert SkillLibrary.relevance_score(skill, "zzzzz") == 0
    end

    test "accumulates scores across multiple field matches" do
      skill = %{
        name: "security-review",
        description: "security analysis tool",
        body: "security best practices",
        tags: ["security"]
      }

      score = SkillLibrary.relevance_score(skill, "security")
      # Should match name (4) + description (3) + tags (2) + body (1) = 10
      assert score == 10
    end

    test "is case insensitive" do
      skill = %{name: "Security-Review", description: "other", body: "other", tags: []}
      assert SkillLibrary.relevance_score(skill, "security") >= 4
    end
  end

  describe "child_spec/1" do
    test "returns a valid child spec" do
      spec = SkillLibrary.child_spec([])

      assert spec.id == SkillLibrary
      assert spec.type == :worker
      assert spec.restart == :permanent
      assert {SkillLibrary, :start_link, [[]]} = spec.start
    end
  end
end
