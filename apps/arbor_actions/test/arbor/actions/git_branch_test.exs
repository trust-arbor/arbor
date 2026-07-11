defmodule Arbor.Actions.GitBranchTest do
  @moduledoc """
  Tests for `Arbor.Actions.Git.Branch` — create / switch / list modes.

  `Git.PR` is tested separately with an injected HTTP client so it never needs
  real SCM credentials or network access.
  """

  use Arbor.Actions.ActionCase, async: false
  @moduletag :fast

  alias Arbor.Actions.Egress
  alias Arbor.Actions.Git

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "repo")
    create_git_repo(repo_path)
    {:ok, repo_path: repo_path}
  end

  describe "Branch :list" do
    test "lists branches with current marker", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Branch.run(%{path: repo_path, mode: :list}, %{})

      assert result.mode == :list
      assert result.current in ["main", "master"]
      assert result.current in result.branches
    end

    test "lists multiple branches after creating one", %{repo_path: repo_path} do
      System.cmd("git", ["branch", "feature-a"], cd: repo_path)

      assert {:ok, result} = Git.Branch.run(%{path: repo_path, mode: :list}, %{})

      assert "feature-a" in result.branches
      assert length(result.branches) >= 2
    end
  end

  describe "Branch :create" do
    test "creates a new branch from HEAD", %{repo_path: repo_path} do
      assert {:ok, result} =
               Git.Branch.run(%{path: repo_path, mode: :create, name: "feature-x"}, %{})

      assert result.mode == :create
      assert result.branch == "feature-x"

      # Confirm we're on the new branch.
      {current, 0} = System.cmd("git", ["branch", "--show-current"], cd: repo_path)
      assert String.trim(current) == "feature-x"
    end

    test "creates a branch from a specific ref", %{repo_path: repo_path} do
      {initial, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      initial_sha = String.trim(initial)

      # Add another commit so HEAD != initial.
      create_file(repo_path, "more.txt", "more")
      System.cmd("git", ["add", "more.txt"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "more"], cd: repo_path)

      assert {:ok, _result} =
               Git.Branch.run(
                 %{path: repo_path, mode: :create, name: "from-initial", from: initial_sha},
                 %{}
               )

      # The new branch should point at initial_sha, not the latest commit.
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      assert String.trim(head) == initial_sha
    end

    test "fails when name is missing" do
      assert {:error, msg} = Git.Branch.run(%{path: "/tmp", mode: :create}, %{})
      assert msg =~ "requires a 'name'"
    end

    test "fails when branch already exists", %{repo_path: repo_path} do
      assert {:ok, _} = Git.Branch.run(%{path: repo_path, mode: :create, name: "dup"}, %{})

      # Try to create again — git refuses.
      assert {:error, msg} = Git.Branch.run(%{path: repo_path, mode: :create, name: "dup"}, %{})
      assert msg =~ "Failed to create branch"
    end
  end

  describe "Branch :switch" do
    test "switches to an existing branch", %{repo_path: repo_path} do
      System.cmd("git", ["branch", "target"], cd: repo_path)

      assert {:ok, result} =
               Git.Branch.run(%{path: repo_path, mode: :switch, name: "target"}, %{})

      assert result.mode == :switch
      assert result.branch == "target"

      {current, 0} = System.cmd("git", ["branch", "--show-current"], cd: repo_path)
      assert String.trim(current) == "target"
    end

    test "fails when switching to non-existent branch", %{repo_path: repo_path} do
      assert {:error, msg} =
               Git.Branch.run(%{path: repo_path, mode: :switch, name: "does-not-exist"}, %{})

      assert msg =~ "Failed to switch"
    end

    test "fails when name is missing" do
      assert {:error, msg} = Git.Branch.run(%{path: "/tmp", mode: :switch}, %{})
      assert msg =~ "requires a 'name'"
    end
  end

  describe "metadata" do
    test "exposes Jido action metadata" do
      assert Git.Branch.name() == "git_branch"
      assert Git.Branch.category() == "git"
      assert "branch" in Git.Branch.tags()
    end

    @tag :security_regression
    test "write-risk metadata security regression: branch is local_write via Egress" do
      # create/switch write; list is read-only. Static class must be max effect.
      assert Egress.effect_class_for(Git.Branch) == :local_write
    end
  end
end
