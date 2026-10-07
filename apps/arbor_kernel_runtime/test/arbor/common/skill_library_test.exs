defmodule Arbor.Common.SkillLibraryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SkillLibrary
  alias Arbor.Contracts.Skill

  @fixtures_dir Path.expand("../../fixtures/skills", __DIR__)
  @fixture_skill_count 4

  # We need a unique table name per test run to avoid conflicts.
  # The SkillLibrary uses a named ETS table, so we start/stop it per test.

  setup do
    # Ensure the GenServer is not running from a previous test
    if Process.whereis(SkillLibrary) do
      GenServer.stop(SkillLibrary)
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

      assert eventually(&fixture_scan_complete?/0)

      # Should have indexed some skills
      assert SkillLibrary.count() > 0

      GenServer.stop(pid)
    end
  end

  describe "get/1" do
    test "returns skill when found in ETS" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert eventually(&fixture_scan_complete?/0)

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
      assert eventually(&fixture_scan_complete?/0)

      skills = SkillLibrary.list()
      assert is_list(skills)
      assert skills != []

      GenServer.stop(pid)
    end

    test "filters by category" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert eventually(&fixture_scan_complete?/0)

      advisory_skills = SkillLibrary.list(category: "advisory")
      assert is_list(advisory_skills)
      assert Enum.all?(advisory_skills, &(Map.get(&1, :category) == "advisory"))

      GenServer.stop(pid)
    end

    test "filters by tags" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert eventually(&fixture_scan_complete?/0)

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
      assert eventually(&fixture_scan_complete?/0)

      fabric_skills = SkillLibrary.list(source: :fabric)
      assert is_list(fabric_skills)
      assert Enum.all?(fabric_skills, &(Map.get(&1, :source) == :fabric))

      GenServer.stop(pid)
    end

    test "returns empty list when no skills match filter" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert eventually(&fixture_scan_complete?/0)

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
      assert eventually(&fixture_scan_complete?/0)

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
      assert eventually(&fixture_scan_complete?/0)

      results = SkillLibrary.search("defensive")
      assert is_list(results)
      assert results != []

      GenServer.stop(pid)
    end

    test "returns empty list for no matches" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert eventually(&fixture_scan_complete?/0)

      results = SkillLibrary.search("zzzznonexistentzzzz")
      assert results == []

      GenServer.stop(pid)
    end

    test "respects limit option" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert eventually(&fixture_scan_complete?/0)

      # Search for something broad that matches multiple skills
      results = SkillLibrary.search("a", limit: 1)
      assert length(results) <= 1

      GenServer.stop(pid)
    end

    test "respects category filter" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])
      assert eventually(&fixture_scan_complete?/0)

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

    test "security regression: public registration cannot mint trusted provenance" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      assert :ok =
               SkillLibrary.register(%{
                 name: "claimed-trusted",
                 description: "Caller supplied",
                 body: "instructions",
                 taint: :trusted,
                 provenance: %{origin: "operator"}
               })

      assert {:ok, skill} = SkillLibrary.get("claimed-trusted")
      assert skill.taint == :untrusted
      assert skill.provenance == %{origin: "runtime_registration"}

      GenServer.stop(pid)
    end

    test "security regression: non-owner processes cannot poison the skill cache" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      assert_raise ArgumentError, fn ->
        :ets.insert(:arbor_skill_library, {"poison", %{taint: :trusted}})
      end

      assert {:error, :not_found} = SkillLibrary.get("poison")
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
      assert eventually(&fixture_scan_complete?/0)

      count = SkillLibrary.count()
      assert count > 0

      GenServer.stop(pid)
    end
  end

  describe "reload/0" do
    test "clears and re-indexes all skills" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@fixtures_dir])

      assert eventually(&fixture_scan_complete?/0)

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

  describe "security review source admission" do
    test "security regression: project skills are untrusted and cannot shadow bundled skills" do
      tmp = scratch_dir!("skill-source")
      project_skills = Path.join([tmp, ".agents", "skills"])
      collision_path = Path.join([project_skills, "collision", "SKILL.md"])
      unique_path = Path.join([project_skills, "project-only", "SKILL.md"])

      write_skill(collision_path, "security-perspective", "PROJECT POISON")
      write_skill(unique_path, "project-only", "project content")

      try do
        File.cd!(tmp, fn ->
          project_root = File.cwd!()
          bundled = Application.app_dir(:arbor_kernel_runtime, "priv/library/skills")
          project = Path.expand(".agents/skills")

          ordered =
            SkillLibrary.default_skill_dirs()
            |> Enum.filter(&(&1 in [bundled, project]))

          assert ordered == [bundled, project]
          assert {:ok, pid} = SkillLibrary.start_link(dirs: [])
          assert {:ok, 2} = SkillLibrary.index(project)
          assert {:ok, bundled_count} = SkillLibrary.index(bundled)
          assert bundled_count > 0

          # Even an explicit overwrite request cannot let the lower-trust
          # project definition replace the bundled definition.
          assert {:ok, 1} = SkillLibrary.index(project, overwrite: true)

          assert {:ok, bundled_skill} = SkillLibrary.get("security-perspective")
          refute bundled_skill.body =~ "PROJECT POISON"
          assert bundled_skill.taint == :trusted
          assert bundled_skill.provenance.origin == "bundled"

          assert {:ok, project_skill} = SkillLibrary.get("project-only")
          assert project_skill.taint == :untrusted
          assert project_skill.provenance.origin == "project:#{project_root}"

          GenServer.stop(pid)
        end)
      after
        File.rm_rf!(tmp)
      end
    end

    test "security regression: scan ignores symlinks and invalid skill names" do
      tmp = scratch_dir!("skill-scan")
      root = Path.join(tmp, "skills")
      outside = Path.join(tmp, "outside")

      write_skill(Path.join([root, "valid", "SKILL.md"]), "valid-skill", "valid")
      write_skill(Path.join([root, "invalid", "SKILL.md"]), "../../invalid", "invalid")
      write_skill(Path.join([outside, "linked", "SKILL.md"]), "linked-poison", "poison")
      File.ln_s!(Path.join(outside, "linked"), Path.join(root, "linked"))

      try do
        assert {:ok, pid} = SkillLibrary.start_link(dirs: [])
        assert {:ok, 1} = SkillLibrary.index(root)

        assert {:ok, valid} = SkillLibrary.get("valid-skill")
        assert valid.taint == :untrusted
        assert valid.provenance.origin == "configured:#{root}"
        assert {:error, :not_found} = SkillLibrary.get("linked-poison")
        assert {:error, :not_found} = SkillLibrary.get("../../invalid")

        GenServer.stop(pid)
      after
        File.rm_rf!(tmp)
      end
    end

    test "security regression: public scan refuses an oversized SKILL.md" do
      tmp = scratch_dir!("skill-size")
      root = Path.join(tmp, "skills")
      oversized = Path.join([root, "oversized", "SKILL.md"])
      File.mkdir_p!(Path.dirname(oversized))

      File.write!(
        oversized,
        "---\nname: oversized-skill\ndescription: oversized fixture\n---\n" <>
          :binary.copy("x", 2 * 1024 * 1024)
      )

      try do
        assert {:ok, %File.Stat{size: size}} = File.stat(oversized)
        assert size > 2 * 1024 * 1024
        assert {:ok, pid} = SkillLibrary.start_link(dirs: [])

        assert {:ok, 0} = SkillLibrary.index(root)
        assert {:error, :not_found} = SkillLibrary.get("oversized-skill")

        GenServer.stop(pid)
      after
        File.rm_rf!(tmp)
      end
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

  defp write_skill(path, name, body) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    name: #{name}
    description: Security regression fixture
    ---

    #{body}
    """)
  end

  defp scratch_dir!(prefix) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "#{prefix}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp eventually(predicate, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(predicate, deadline)
  end

  defp fixture_scan_complete?, do: SkillLibrary.count() == @fixture_skill_count

  defp eventually_until(predicate, deadline) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          10 -> eventually_until(predicate, deadline)
        end
    end
  end
end
