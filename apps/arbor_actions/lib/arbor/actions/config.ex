defmodule Arbor.Actions.Config do
  @moduledoc """
  Configuration helpers for action modules.

  This keeps deployment-specific values out of action business logic while still
  giving tests and system callers a narrow override point. Secrets are resolved
  from context/application config/env, but actions should never expose them in
  schemas or logs.
  """

  @type provider :: :github | :gitlab | :gitea

  @provider_env %{
    github: ["GITHUB_TOKEN", "GH_TOKEN"],
    gitlab: ["GITLAB_TOKEN"],
    gitea: ["GITEA_TOKEN", "FORGEJO_TOKEN"]
  }

  @spec get(map(), atom(), any()) :: any()
  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  def get(_map, _key, default), do: default

  @spec scm_provider(map(), map(), map() | nil) :: {:ok, provider()} | {:error, String.t()}
  def scm_provider(params, context, remote_info \\ nil) do
    params
    |> get(:provider)
    |> first_present(get(context, :scm_provider))
    |> first_present(Application.get_env(:arbor_actions, :scm_provider))
    |> first_present(inferred_provider(remote_info))
    |> normalize_provider()
  end

  @spec scm_base_url(provider(), map(), map(), map() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def scm_base_url(provider, params, context, remote_info \\ nil) do
    params
    |> get(:scm_base_url)
    |> first_present(get(params, :base_url))
    |> first_present(get(context, :scm_base_url))
    |> first_present(get(context, :base_url))
    |> first_present(Application.get_env(:arbor_actions, :scm_base_url))
    |> first_present(inferred_base_url(provider, remote_info))
    |> normalize_base_url()
  end

  @spec scm_token(provider(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def scm_token(provider, params, context) do
    token =
      context_token(provider, context) ||
        config_token(provider, params, context) ||
        env_token(provider)

    case token do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "SCM token is not configured"}
    end
  end

  @spec redact_secret(String.t(), String.t() | nil) :: String.t()
  def redact_secret(text, secret) when is_binary(text) and is_binary(secret) and secret != "" do
    String.replace(text, secret, "[REDACTED]")
  end

  def redact_secret(text, _secret) when is_binary(text), do: text

  defp context_token(provider, context) do
    get(context, :scm_token) ||
      get_nested_token(get(context, :scm_tokens, %{}), provider)
  end

  defp config_token(provider, _params, _context) do
    direct = Application.get_env(:arbor_actions, :scm_token)

    provider_token =
      get_nested_token(Application.get_env(:arbor_actions, :scm_tokens, %{}), provider)

    direct
    |> first_present(provider_token)
    |> resolve_secret_value()
  end

  defp get_nested_token(tokens, provider) when is_map(tokens) do
    Map.get(tokens, provider) || Map.get(tokens, Atom.to_string(provider))
  end

  defp get_nested_token(_tokens, _provider), do: nil

  defp resolve_secret_value({:system, env_var}) when is_binary(env_var),
    do: System.get_env(env_var)

  defp resolve_secret_value({:env, env_var}) when is_binary(env_var), do: System.get_env(env_var)
  defp resolve_secret_value(value), do: value

  defp env_token(provider) do
    ["ARBOR_SCM_TOKEN" | Map.get(@provider_env, provider, [])]
    |> Enum.find_value(fn env_var ->
      case System.get_env(env_var) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp normalize_provider(provider) when provider in [:github, :gitlab, :gitea],
    do: {:ok, provider}

  defp normalize_provider(provider) when is_binary(provider) do
    case String.downcase(provider) do
      "github" -> {:ok, :github}
      "gitlab" -> {:ok, :gitlab}
      "gitea" -> {:ok, :gitea}
      "forgejo" -> {:ok, :gitea}
      other -> {:error, "unsupported SCM provider: #{other}"}
    end
  end

  defp normalize_provider(nil), do: {:error, "SCM provider could not be resolved"}

  defp normalize_provider(provider),
    do: {:error, "unsupported SCM provider: #{inspect(provider)}"}

  defp normalize_base_url(value) when is_binary(value) do
    value = String.trim_trailing(value, "/")

    if value == "" do
      {:error, "SCM base URL is not configured"}
    else
      {:ok, value}
    end
  end

  defp normalize_base_url(_), do: {:error, "SCM base URL is not configured"}

  defp inferred_provider(%{host: host}) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host == "github.com" or String.ends_with?(host, ".github.com") -> :github
      host == "gitlab.com" or String.ends_with?(host, ".gitlab.com") -> :gitlab
      true -> :gitea
    end
  end

  defp inferred_provider(_), do: nil

  defp inferred_base_url(:github, %{host: "github.com"}), do: "https://api.github.com"
  defp inferred_base_url(:gitlab, %{host: "gitlab.com"}), do: "https://gitlab.com"

  defp inferred_base_url(_provider, %{scheme: scheme, host: host, port: port})
       when is_binary(scheme) and is_binary(host) do
    port_part = if port, do: ":#{port}", else: ""
    "#{scheme}://#{host}#{port_part}"
  end

  defp inferred_base_url(_provider, %{host: host}) when is_binary(host), do: "https://#{host}"
  defp inferred_base_url(_provider, _remote_info), do: nil

  defp first_present(nil, fallback), do: fallback
  defp first_present("", fallback), do: fallback
  defp first_present(value, _fallback), do: value
end
