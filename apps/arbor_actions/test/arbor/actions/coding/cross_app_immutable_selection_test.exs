defmodule Arbor.Actions.Coding.CrossAppImmutableSelectionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.CrossApp.Shell
  alias Arbor.Actions.Git

  @moduletag :fast

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  test "resolve_commit_selection uses immutable commit mix.exs despite hostile worktree bytes", %{
    tmp_dir: tmp_dir
  } do
    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    write_mix!(repo, "alpha", alpha_mix("alpha", []))
    git!(repo, ["add", "apps/alpha/mix.exs"])
    git!(repo, ["commit", "-m", "base alpha"])
    base = git!(repo, ["rev-parse", "HEAD"])

    write_mix!(repo, "alpha", alpha_mix("alpha", ["beta"]))
    write_mix!(repo, "beta", alpha_mix("beta", []))
    git!(repo, ["add", "apps/alpha/mix.exs", "apps/beta/mix.exs"])
    git!(repo, ["commit", "-m", "add beta dep"])
    source = git!(repo, ["rev-parse", "HEAD"])
    {:ok, tree} = Git.commit_tree_oid(repo, source)

    File.write!(Path.join(repo, "apps/alpha/mix.exs"), alpha_mix("alpha", ["hostile"]))
    File.write!(Path.join(repo, "apps/beta/mix.exs"), "not even elixir")

    assert {:ok, resolved} = Shell.resolve_commit_selection(repo, base, source)
    assert resolved.candidate_tree_oid == tree
    assert {"alpha", alpha_source} = List.keyfind(resolved.candidate_app_mix_exs, "alpha", 0)
    assert alpha_source == alpha_mix("alpha", ["beta"])
    refute alpha_source =~ "hostile"

    assert "beta" in resolved.selection.affected_apps or
             "alpha" in resolved.selection.affected_apps
  end

  defp write_mix!(repo, app, source) do
    dir = Path.join([repo, "apps", app])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), source)
  end

  defp alpha_mix(app, deps) do
    dep_entries =
      Enum.map_join(deps, ",\n          ", fn dep ->
        "{:#{dep}, in_umbrella: true}"
      end)

    """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          deps: deps()
        ]
      end

      defp deps do
        [
          #{dep_entries}
        ]
      end
    end
    """
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
