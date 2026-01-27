defmodule Arbor.Actions.ActionCase do
  @moduledoc """
  Test case for Arbor.Actions tests.

  Provides common setup and helpers for testing actions.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Arbor.Actions.ActionCase

      alias Arbor.Actions
    end
  end

  setup do
    # Create a unique temp directory for each test
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_actions_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  @doc """
  Create a test git repository.
  """
  def create_git_repo(path) do
    File.mkdir_p!(path)

    # Initialize repo
    {_, 0} = System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)

    # Configure git user for the repo
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: path)

    # Create initial commit
    readme_path = Path.join(path, "README.md")
    File.write!(readme_path, "# Test Repository\n")
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: path)
    {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)

    path
  end

  @doc """
  Create a file in the given directory.
  """
  def create_file(dir, name, content \\ "") do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  @doc """
  Assert action result is successful.
  """
  defmacro assert_ok({:ok, result}) do
    quote do
      assert {:ok, _} = unquote({:ok, result})
    end
  end

  @doc """
  Assert action result is an error.
  """
  defmacro assert_error({:error, _} = result) do
    quote do
      assert {:error, _} = unquote(result)
    end
  end
end
