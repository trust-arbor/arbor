defmodule Arbor.LLM.Plugs.FixturePackageLocationTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.Plugs.Fixture

  @moduletag :fast
  @moduletag :tmp_dir

  setup do
    previous = Application.fetch_env(:arbor_llm, :recorder)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_llm, :recorder, value)
        :error -> Application.delete_env(:arbor_llm, :recorder)
      end
    end)

    Application.delete_env(:arbor_llm, :recorder)
    :ok
  end

  test "repository and package callers resolve the canonical package recordings", %{tmp_dir: root} do
    package = Path.join(root, "packages/arbor_llm")
    File.mkdir_p!(package)
    File.write!(Path.join(package, "mix.exs"), "# package location fixture\n")
    expected = Path.join(package, "test/fixtures/llm_recordings")

    for cwd <- [root, package] do
      File.cd!(cwd, fn -> assert Fixture.fixtures_root() == expected end)
    end
  end

  test "ordinary consumers retain their cwd default and an explicit override wins", %{
    tmp_dir: root
  } do
    File.cd!(root, fn ->
      assert Fixture.fixtures_root() == Path.join(root, "test/fixtures/llm_recordings")
      custom = Path.join(root, "private-recordings")
      Application.put_env(:arbor_llm, :recorder, fixtures_path: custom)
      assert Fixture.fixtures_root() == custom
    end)
  end
end
