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

  @workspace_retention_default_ms 24 * 60 * 60 * 1_000
  @workspace_retention_min_ms 1_000
  @workspace_retention_max_ms 7 * 24 * 60 * 60 * 1_000

  @doc """
  Return the bounded retained-workspace TTL.

  The TTL is operator configuration only. Action parameters are deliberately
  not consulted here, so an agent cannot extend a retained workspace lifetime.
  Registry test servers may pass an explicit `:retention_ttl_ms` start option.
  """
  @spec workspace_retention_ttl_ms(keyword()) :: pos_integer()
  def workspace_retention_ttl_ms(opts \\ []) do
    configured =
      Keyword.get(
        opts,
        :retention_ttl_ms,
        Application.get_env(:arbor_actions, :workspace_retention_ttl_ms)
      )

    configured
    |> normalize_positive_integer(@workspace_retention_default_ms)
    |> min(@workspace_retention_max_ms)
    |> max(@workspace_retention_min_ms)
  end

  @spec workspace_retention_min_ttl_ms() :: pos_integer()
  def workspace_retention_min_ttl_ms, do: @workspace_retention_min_ms

  @spec workspace_retention_max_ttl_ms() :: pos_integer()
  def workspace_retention_max_ttl_ms, do: @workspace_retention_max_ms

  @doc """
  Absolute directory for the node-restart durable retained-workspace journal.

  Defaults to `$ARBOR_HOME/workspace_retention` (or `~/.arbor/workspace_retention`
  when `ARBOR_HOME` is unset) — never the repository CWD. Operators may override
  via `Application.put_env(:arbor_actions, :workspace_retention_journal_path, path)`.
  Configured paths and `ARBOR_HOME` must be absolute; relative values raise
  rather than being silently resolved against the process working directory.
  Tests inject a private temp path through the durable store's `:path` start option
  and must not share the production home journal.
  """
  @spec workspace_retention_journal_path() :: String.t()
  def workspace_retention_journal_path do
    case Application.fetch_env(:arbor_actions, :workspace_retention_journal_path) do
      {:ok, path} ->
        require_absolute_retention_path!(path, :workspace_retention_journal_path)

      :error ->
        arbor_home =
          case System.get_env("ARBOR_HOME") do
            home when is_binary(home) and home != "" ->
              require_absolute_retention_path!(home, :arbor_home)

            _ ->
              Path.expand("~/.arbor")
          end

        Path.join(arbor_home, "workspace_retention")
    end
  end

  defp require_absolute_retention_path!(path, source)
       when is_binary(path) and path != "" do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      raise ArgumentError,
            "#{source} must be an absolute path; relative paths must not depend on CWD"
    end
  end

  defp require_absolute_retention_path!(_path, source) do
    raise ArgumentError, "#{source} must be a non-empty absolute path"
  end

  @doc """
  Whether the application-owned retained-workspace durable journal is enabled.

  Production/default is **on** (node-restart durability). `config/test.exs`
  explicitly disables it so the application supervisor never opens
  `~/.arbor/workspace_retention` or hydrates production evidence under
  `MIX_ENV=test`. Focused restart tests inject private temp-backed stores.
  """
  @spec workspace_retention_journal_enabled?() :: boolean()
  def workspace_retention_journal_enabled? do
    case Application.get_env(:arbor_actions, :workspace_retention_journal_enabled, true) do
      false -> false
      :disabled -> false
      "false" -> false
      "0" -> false
      0 -> false
      _ -> true
    end
  end

  @doc """
  Journal option for the application-owned `WorkspaceLeaseRegistry` child.

  When enabled, binds the production `WorkspaceRetentionDurableStore` process
  name. When disabled (tests), returns `:disabled` so no durable hydrate/allocate
  path touches the home journal.
  """
  @spec application_retention_journal() ::
          :disabled | {module(), module()}
  def application_retention_journal do
    if workspace_retention_journal_enabled?() do
      store = Arbor.Actions.Coding.WorkspaceRetentionDurableStore
      {store, store}
    else
      :disabled
    end
  end

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

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, default), do: default

  @doc """
  Public AI facade module used by ACP (and similar) actions.

  Defaults to `Arbor.AI`. Tests may override via
  `Application.put_env(:arbor_actions, :ai_module, FakeAI)`.
  Actions must call only this public facade, never arbor_ai internals.
  """
  @spec ai_module() :: module()
  def ai_module do
    Application.get_env(:arbor_actions, :ai_module, Arbor.AI)
  end

  @doc """
  Public Shell facade used by the schema-bounded Mix actions.

  Production defaults to `Arbor.Shell`. Tests may configure a trusted named
  module with `:mix_shell_module` so action behavior can be exercised without
  claiming production process containment. This seam is operator/test
  configuration only; actions never resolve it from params or context, and
  function values are not accepted. Misconfigured modules fail closed before
  dispatch.
  """
  @type mix_shell_module_error ::
          {:invalid_mix_shell_module,
           :named_module_required
           | {:module_not_loaded, module()}
           | {:callback_not_exported, module(), atom(), non_neg_integer()}}

  @spec mix_shell_module() :: {:ok, module()} | {:error, mix_shell_module_error()}
  def mix_shell_module do
    case Application.get_env(:arbor_actions, :mix_shell_module, Arbor.Shell) do
      module when is_atom(module) ->
        cond do
          not Code.ensure_loaded?(module) ->
            {:error, {:invalid_mix_shell_module, {:module_not_loaded, module}}}

          not function_exported?(module, :execute_spawn_capable, 3) ->
            {:error,
             {:invalid_mix_shell_module,
              {:callback_not_exported, module, :execute_spawn_capable, 3}}}

          true ->
            {:ok, module}
        end

      _other ->
        {:error, {:invalid_mix_shell_module, :named_module_required}}
    end
  end

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
