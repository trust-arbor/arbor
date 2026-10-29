defmodule Arbor.OptionalApps do
  @moduledoc false

  @voice_apps [:arbor_voice, :arbor_multimedia]

  # This is a build selector, read before config/runtime.exs or .env is loaded.
  # Freeze it once so later dotenv loading cannot disagree with root discovery.
  @build_env %{"ARBOR_VOICE" => System.get_env("ARBOR_VOICE")}

  @spec voice_enabled?(map()) :: boolean()
  def voice_enabled?(env \\ @build_env) do
    case Map.get(env, "ARBOR_VOICE") do
      value when value in [nil, "", "0", "false"] -> false
      value when value in ["1", "true"] -> true
      _ -> raise ArgumentError, "ARBOR_VOICE must be true or false (also accepts 1 or 0)"
    end
  end

  @spec apps(String.t(), map()) :: [atom()]
  def apps(apps_path, env \\ @build_env) do
    disabled = if voice_enabled?(env), do: [], else: Enum.map(@voice_apps, &Atom.to_string/1)

    apps_path
    |> File.ls!()
    |> Enum.reject(&(&1 in disabled))
    |> Enum.filter(&File.regular?(Path.join([apps_path, &1, "mix.exs"])))
    |> Enum.sort()
    # Only trusted, repository-owned app directory names, just like Mix discovery.
    |> Enum.map(&String.to_atom/1)
  end

  @spec filter_deps([tuple()], map()) :: [tuple()]
  def filter_deps(deps, env \\ @build_env) do
    if voice_enabled?(env), do: deps, else: Enum.reject(deps, &(elem(&1, 0) in @voice_apps))
  end
end
