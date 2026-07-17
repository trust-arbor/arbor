defmodule Arbor.MixProjectPaths do
  @moduledoc false

  @contained_mode "1"

  @spec project_paths(keyword(), map()) :: keyword()
  def project_paths(fallbacks, env) when is_list(fallbacks) and is_map(env) do
    if Map.get(env, "ARBOR_MIX_CONTAINED") == @contained_mode do
      [
        build_path: contained_path!(env, "MIX_BUILD_PATH"),
        deps_path: contained_path!(env, "MIX_DEPS_PATH")
      ]
    else
      [
        build_path: Keyword.fetch!(fallbacks, :build_path),
        deps_path: Keyword.fetch!(fallbacks, :deps_path)
      ]
    end
  end

  @spec project_paths(keyword()) :: keyword()
  def project_paths(fallbacks) when is_list(fallbacks) do
    project_paths(fallbacks, System.get_env())
  end

  defp contained_path!(env, key) do
    case Map.get(env, key) do
      path when is_binary(path) ->
        if path != "" and canonical_absolute?(path) do
          path
        else
          invalid_contained_path!(key)
        end

      _ ->
        invalid_contained_path!(key)
    end
  end

  defp invalid_contained_path!(key) do
    raise ArgumentError,
          "contained Mix requires #{key} to be a non-empty canonical absolute path"
  end

  defp canonical_absolute?(path) do
    String.valid?(path) and not String.contains?(path, <<0>>) and String.trim(path) == path and
      Path.type(path) == :absolute and Path.expand(path) == path
  end
end
