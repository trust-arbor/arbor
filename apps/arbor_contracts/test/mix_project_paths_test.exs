defmodule Arbor.MixProjectPathsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @root Path.expand("../../..", __DIR__)
  @helper Path.join(@root, "build_support/mix_project_paths.exs")

  Code.require_file(@helper)

  @fallbacks [build_path: "../../_build", deps_path: "../../deps"]

  describe "project_paths/2" do
    test "preserves the existing relative fallbacks outside contained mode" do
      assert Arbor.MixProjectPaths.project_paths(@fallbacks, %{
               "ARBOR_MIX_CONTAINED" => "0",
               "MIX_BUILD_PATH" => "/ignored/build",
               "MIX_DEPS_PATH" => "/ignored/deps"
             }) == @fallbacks
    end

    test "uses canonical absolute paths in contained mode" do
      env = %{
        "ARBOR_MIX_CONTAINED" => "1",
        "MIX_BUILD_PATH" => "/arbor/build",
        "MIX_DEPS_PATH" => "/arbor/deps"
      }

      assert Arbor.MixProjectPaths.project_paths(@fallbacks, env) == [
               build_path: "/arbor/build",
               deps_path: "/arbor/deps"
             ]
    end

    test "fails closed for missing, empty, relative, and noncanonical paths" do
      invalid_envs = [
        %{"ARBOR_MIX_CONTAINED" => "1", "MIX_DEPS_PATH" => "/arbor/deps"},
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "",
          "MIX_DEPS_PATH" => "/arbor/deps"
        },
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "build",
          "MIX_DEPS_PATH" => "/arbor/deps"
        },
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "/arbor/build/../build",
          "MIX_DEPS_PATH" => "/arbor/deps"
        },
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "/arbor/build",
          "MIX_DEPS_PATH" => "/arbor/deps/"
        }
      ]

      Enum.each(invalid_envs, fn env ->
        assert_raise ArgumentError, ~r/contained Mix requires/, fn ->
          Arbor.MixProjectPaths.project_paths(@fallbacks, env)
        end
      end)
    end
  end

  test "every git-tracked project file uses the shared path helper" do
    paths = tracked_mix_files()

    assert paths != []

    Enum.each(paths, fn path ->
      source = File.read!(path)
      ast = Code.string_to_quoted!(source)

      assert source =~ "Code.require_file"
      assert source =~ "build_support/mix_project_paths.exs"

      assert Enum.any?(project_path_calls(ast), fn args ->
               Keyword.has_key?(args, :build_path) and Keyword.has_key?(args, :deps_path)
             end),
             "#{Path.relative_to(path, @root)} does not configure both Mix paths through the shared helper"

      assert source =~ ~r/build_path:\s*paths\[:build_path\]/
      assert source =~ ~r/deps_path:\s*paths\[:deps_path\]/
    end)
  end

  defp tracked_mix_files do
    {output, 0} =
      System.cmd("git", ["-C", @root, "ls-files", "--", "mix.exs", "apps/*/mix.exs"],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Path.join(@root, &1))
  end

  defp project_path_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Arbor, :MixProjectPaths]}, :project_paths]}, _, [args]} =
            node,
        calls
        when is_list(args) ->
          if Keyword.keyword?(args), do: {node, [args | calls]}, else: {node, calls}

        node, calls ->
          {node, calls}
      end)

    calls
  end
end
