defmodule Arbor.Actions.GitTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Git

  # Start shell system for tests
  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _} = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "repo")
    create_git_repo(repo_path)
    {:ok, repo_path: repo_path}
  end

  describe "Status" do
    test "returns clean status for clean repo", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.path == repo_path
      assert result.is_clean == true
      assert result.staged == []
      assert result.modified == []
      assert result.untracked == []
    end

    test "detects untracked files", %{repo_path: repo_path} do
      create_file(repo_path, "new_file.txt", "content")

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.is_clean == false
      assert "new_file.txt" in result.untracked
    end

    test "detects modified files", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Modified content")

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.is_clean == false
      assert "README.md" in result.modified
    end

    test "detects staged files", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Modified content")
      System.cmd("git", ["add", "README.md"], cd: repo_path)

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.is_clean == false
      assert "README.md" in result.staged
    end

    test "reports current branch", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      # Branch is either "master" or "main" depending on git config
      assert result.branch in ["master", "main"]
    end

    test "returns error for non-git directory" do
      assert {:error, message} = Git.Status.run(%{path: "/tmp"}, %{})
      assert message =~ "Failed to get git status" or message =~ "not a git repository"
    end

    test "validates action metadata" do
      assert Git.Status.name() == "git_status"
      assert Git.Status.category() == "git"
      assert "status" in Git.Status.tags()
    end

    test "generates tool schema" do
      tool = Git.Status.to_tool()
      assert is_map(tool)
      assert tool[:name] == "git_status"
    end
  end

  describe "Diff" do
    test "shows empty diff for clean repo", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Diff.run(%{path: repo_path}, %{})

      assert result.path == repo_path
      assert result.diff == ""
    end

    test "shows diff for modified file", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Modified content\n")

      assert {:ok, result} = Git.Diff.run(%{path: repo_path}, %{})

      assert result.diff =~ "Modified content"
      assert result.diff =~ "diff --git"
    end

    test "shows staged diff", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Staged content\n")
      System.cmd("git", ["add", "README.md"], cd: repo_path)

      assert {:ok, result} = Git.Diff.run(%{path: repo_path, staged: true}, %{})

      assert result.diff =~ "Staged content"
    end

    test "shows stat only", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "New line 1\nNew line 2\n")

      assert {:ok, result} = Git.Diff.run(%{path: repo_path, stat_only: true}, %{})

      assert Map.has_key?(result, :files_changed)
      assert Map.has_key?(result, :insertions)
      assert Map.has_key?(result, :deletions)
    end

    test "diffs specific file", %{repo_path: repo_path} do
      # Create and modify two files
      readme_path = Path.join(repo_path, "README.md")
      other_path = Path.join(repo_path, "other.txt")
      File.write!(readme_path, "README modified\n")
      File.write!(other_path, "other content\n")

      # Diff only README
      assert {:ok, result} = Git.Diff.run(%{path: repo_path, file: "README.md"}, %{})

      assert result.diff =~ "README modified"
      refute result.diff =~ "other content"
    end

    test "validates action metadata" do
      assert Git.Diff.name() == "git_diff"
      assert "diff" in Git.Diff.tags()
    end
  end

  describe "Commit" do
    test "creates commit with staged files", %{repo_path: repo_path} do
      # Create and stage a new file
      create_file(repo_path, "new_file.txt", "content")
      System.cmd("git", ["add", "new_file.txt"], cd: repo_path)

      assert {:ok, result} = Git.Commit.run(%{path: repo_path, message: "Add new file"}, %{})

      assert result.path == repo_path
      assert String.length(result.commit_hash) >= 7
      assert result.message == "Add new file"
    end

    test "stages and commits specified files", %{repo_path: repo_path} do
      create_file(repo_path, "file1.txt", "content1")
      create_file(repo_path, "file2.txt", "content2")

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Add files", files: ["file1.txt", "file2.txt"]},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "stages all with -A flag", %{repo_path: repo_path} do
      create_file(repo_path, "file1.txt", "content1")
      create_file(repo_path, "file2.txt", "content2")

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Add all files", all: true},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "handles commit with no changes", %{repo_path: repo_path} do
      assert {:error, message} = Git.Commit.run(%{path: repo_path, message: "Empty"}, %{})
      assert message =~ "nothing to commit" or message =~ "Failed to create commit"
    end

    test "allows empty commit when specified", %{repo_path: repo_path} do
      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Empty commit", allow_empty: true},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "handles special characters in commit message", %{repo_path: repo_path} do
      create_file(repo_path, "file.txt", "content")

      message = "Fix bug: \"quoted\" and 'apostrophe' and $special"

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: message, files: ["file.txt"]},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "validates action metadata" do
      assert Git.Commit.name() == "git_commit"
      assert "commit" in Git.Commit.tags()
    end
  end

  describe "Log" do
    test "shows commit history", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Log.run(%{path: repo_path}, %{})

      assert result.path == repo_path
      assert length(result.commits) >= 1
      assert result.count >= 1

      first_commit = hd(result.commits)
      assert Map.has_key?(first_commit, :hash)
      assert Map.has_key?(first_commit, :author)
      assert Map.has_key?(first_commit, :subject)
    end

    test "limits number of commits", %{repo_path: repo_path} do
      # Create some commits
      for i <- 1..5 do
        create_file(repo_path, "file#{i}.txt", "content")
        System.cmd("git", ["add", "file#{i}.txt"], cd: repo_path)
        System.cmd("git", ["commit", "-m", "Commit #{i}"], cd: repo_path)
      end

      assert {:ok, result} = Git.Log.run(%{path: repo_path, limit: 3}, %{})

      assert result.count == 3
    end

    test "shows oneline format", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Log.run(%{path: repo_path, oneline: true}, %{})

      first_commit = hd(result.commits)
      assert Map.has_key?(first_commit, :hash)
      assert Map.has_key?(first_commit, :message)
      # Oneline format has fewer fields
      refute Map.has_key?(first_commit, :email)
    end

    test "filters by file", %{repo_path: repo_path} do
      # Create commits affecting different files
      create_file(repo_path, "file1.txt", "content")
      System.cmd("git", ["add", "file1.txt"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "Add file1"], cd: repo_path)

      create_file(repo_path, "file2.txt", "content")
      System.cmd("git", ["add", "file2.txt"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "Add file2"], cd: repo_path)

      # Filter to only file1
      assert {:ok, result} = Git.Log.run(%{path: repo_path, file: "file1.txt"}, %{})

      # Should only show commits affecting file1
      assert result.count == 1
      first_commit = hd(result.commits)
      assert first_commit.subject =~ "file1"
    end

    test "handles non-git directory" do
      # /tmp might have git history on some systems, use a definitely non-git path
      non_git_path = Path.join(System.tmp_dir!(), "non_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(non_git_path)

      on_exit(fn -> File.rm_rf!(non_git_path) end)

      result = Git.Log.run(%{path: non_git_path}, %{})

      case result do
        {:error, message} ->
          assert message =~ "Failed to get git log" or message =~ "not a git repository"

        {:ok, %{commits: commits}} ->
          # If it succeeds, it should return empty commits
          assert commits == []
      end
    end

    test "validates action metadata" do
      assert Git.Log.name() == "git_log"
      assert "history" in Git.Log.tags()
    end

    test "generates tool schema" do
      tool = Git.Log.to_tool()
      assert is_map(tool)
      assert tool[:name] == "git_log"
    end
  end
end
