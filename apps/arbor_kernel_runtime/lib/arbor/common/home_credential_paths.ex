defmodule Arbor.Common.HomeCredentialPaths do
  @moduledoc """
  Home-relative credential paths shared by shell containment and reflexes.

  The names come from `Arbor.Shell.AgentContainment`'s protected-path
  policy. Both that module and `Arbor.Security.Reflex.Builtin` read this
  list so the two surfaces cannot drift.

  Expansion honors both `$HOME` and the VM boot home. Elixir's
  `System.user_home/0` and `Path.expand("~")` read `:init.get_argument(:home)`,
  which is fixed at boot and ignores a later `HOME` change — tests and
  process-local home overrides must still block the active `$HOME`.
  """

  alias Arbor.Common.SafePath

  @type kind :: :file | :directory

  @type entry :: %{
          id: String.t(),
          glob: String.t(),
          kind: kind()
        }

  @entries [
    %{id: "aws_credentials", glob: "~/.aws/credentials", kind: :file},
    %{id: "aws_config", glob: "~/.aws/config", kind: :file},
    %{id: "ssh_config", glob: "~/.ssh/config", kind: :file},
    %{id: "azure_credentials", glob: "~/.azure", kind: :directory},
    %{id: "gcloud_config", glob: "~/.config/gcloud", kind: :directory},
    %{id: "kube_config", glob: "~/.kube/config", kind: :file},
    %{id: "docker_config", glob: "~/.docker/config.json", kind: :file},
    %{id: "netrc", glob: "~/.netrc", kind: :file},
    %{id: "npm_tokens", glob: "~/.npmrc", kind: :file},
    %{id: "pypirc", glob: "~/.pypirc", kind: :file},
    %{id: "gnupg", glob: "~/.gnupg", kind: :directory}
  ]

  @doc """
  Structured credential paths used to generate blocking reflexes.
  """
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc """
  Candidate paths from a reflex check context.
  """
  @spec context_paths(map()) :: [String.t()]
  def context_paths(context) when is_map(context) do
    [Map.get(context, :path), Map.get(context, :file_path) | List.wrap(Map.get(context, :paths))]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  Expand `~`, `$HOME`, and `${HOME}` against the preferred current home.

  Prefer `$HOME` when it is set so process-local home overrides are visible;
  fall back to the VM boot home. See `expand_all/1` when both must be tried.
  """
  @spec expand(String.t()) :: String.t()
  def expand(path) when is_binary(path) do
    case expand_all(path) do
      [first | _] -> first
      [] -> path
    end
  end

  @doc """
  Every expansion of `path` against `$HOME` and the VM boot home.
  """
  @spec expand_all(String.t()) :: [String.t()]
  def expand_all(path) when is_binary(path) do
    homes()
    |> case do
      [] -> [expand_with_home(path, nil)]
      homes -> Enum.map(homes, &expand_with_home(path, &1))
    end
    |> Enum.uniq()
  end

  @doc """
  True when `path` is the credential file or inside the credential directory.
  """
  @spec path_match?(entry(), String.t()) :: boolean()
  def path_match?(%{glob: glob, kind: :file}, path) when is_binary(path) do
    path_candidates = expand_all(path)
    glob_candidates = expand_all(glob)

    Enum.any?(path_candidates, fn expanded_path ->
      Enum.any?(glob_candidates, fn expanded_glob ->
        path_equals?(expanded_path, expanded_glob) or
          wildcard_match?(expanded_glob, expanded_path)
      end)
    end)
  end

  def path_match?(%{glob: glob, kind: :directory}, path) when is_binary(path) do
    path_candidates = expand_all(path)
    dir_candidates = expand_all(glob)

    Enum.any?(path_candidates, fn expanded_path ->
      Enum.any?(dir_candidates, fn expanded_dir ->
        path_equals?(expanded_path, expanded_dir) or
          String.starts_with?(expanded_path, expanded_dir <> "/")
      end)
    end)
  end

  def path_match?(_entry, _path), do: false

  @doc """
  True when any context path matches the credential entry.
  """
  @spec blocked?(entry(), map()) :: boolean()
  def blocked?(entry, context) when is_map(context) do
    Enum.any?(context_paths(context), &path_match?(entry, &1))
  end

  defp homes do
    [System.get_env("HOME"), System.user_home()]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&String.trim_trailing(&1, "/"))
    |> Enum.uniq()
  end

  defp expand_with_home(path, home) do
    rewritten = rewrite_home_prefixes(path, home)

    if String.contains?(rewritten, ["*", "?"]) do
      rewritten
    else
      case SafePath.resolve_real(rewritten) do
        {:ok, real} -> real
        _ -> rewritten
      end
    end
  rescue
    _ -> path
  end

  defp rewrite_home_prefixes(path, home) when is_binary(home) do
    path
    |> String.replace_prefix("/${HOME}", home)
    |> String.replace_prefix("/$HOME", home)
    |> String.replace_prefix("${HOME}", home)
    |> String.replace_prefix("$HOME", home)
    |> rewrite_tilde(home)
    |> finalize_path()
  end

  defp rewrite_home_prefixes(path, _home), do: finalize_path(path)

  # Elixir Path.expand("~") uses the VM boot home, not $HOME.
  defp rewrite_tilde("~", home), do: home
  defp rewrite_tilde(<<"~/", rest::binary>>, home), do: Path.join(home, rest)
  defp rewrite_tilde("/~", home), do: home
  defp rewrite_tilde(<<"/~/", rest::binary>>, home), do: Path.join(home, rest)
  defp rewrite_tilde(path, _home), do: path

  defp finalize_path(path) do
    if String.starts_with?(path, "~") do
      path
    else
      Path.expand(path)
    end
  end

  defp path_equals?(left, right), do: left == right

  defp wildcard_match?(glob, path) do
    if String.contains?(glob, ["*", "?"]) do
      pattern =
        glob
        |> Regex.escape()
        |> String.replace("\\*\\*", ".*")
        |> String.replace("\\*", "[^/]*")
        |> String.replace("\\?", ".")

      # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
      Regex.match?(Regex.compile!("^" <> pattern <> "$"), path)
    else
      false
    end
  end
end
