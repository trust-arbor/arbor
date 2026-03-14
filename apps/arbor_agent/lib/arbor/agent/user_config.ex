defmodule Arbor.Agent.UserConfig do
  @moduledoc """
  Per-user configuration store backed by `Arbor.Persistence.BufferedStore`.

  Provides persistent per-user settings (API keys, default model/provider,
  workspace preferences, notification settings). Settings are keyed by the
  user's principal ID (`human_<hash>`).

  ## Config Resolution Cascade

  UserConfig participates in a tiered resolution chain:

      Environment vars → Application config → User config → Per-agent overrides

  Use `get_effective/3` for cascaded resolution, or `get/2` for user-specific
  values only.

  ## Usage

      # Store a setting
      UserConfig.put("human_abc123", :default_model, "claude-sonnet-4-5-20250514")

      # Read a setting
      UserConfig.get("human_abc123", :default_model)
      #=> "claude-sonnet-4-5-20250514"

      # Cascaded resolution (user → app → default)
      UserConfig.get_effective("human_abc123", :default_model, "claude-haiku-3-5-20241022")
      #=> "claude-sonnet-4-5-20250514"  (user override wins)

      # Bulk operations
      UserConfig.get_all("human_abc123")
      #=> %{default_model: "claude-sonnet-4-5-20250514", ...}

  ## Known Settings

  | Key                  | Type   | Description                          |
  |----------------------|--------|--------------------------------------|
  | `:default_model`     | string | Default LLM model for new agents     |
  | `:default_provider`  | atom   | Default LLM provider (:anthropic, etc.) |
  | `:api_keys`          | map    | Per-provider API key overrides       |
  | `:workspace_root`    | string | Custom workspace path override       |
  | `:notification_prefs`| map    | Notification preferences             |
  | `:timezone`          | string | User's timezone for display          |

  ## Supervision

  Started as a `BufferedStore` child in `Arbor.Agent.Application`.
  The store name is `:arbor_user_config`.
  """

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.BufferedStore

  require Logger

  @store_name :arbor_user_config

  # App-level config key for system-wide defaults
  @app_config_key :user_defaults

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Store a setting for a user.

  ## Examples

      UserConfig.put("human_abc123", :default_model, "claude-sonnet-4-5-20250514")
  """
  @spec put(String.t(), atom(), term()) :: :ok | {:error, term()}
  def put(principal_id, key, value) when is_binary(principal_id) and is_atom(key) do
    if available?() do
      config = load_config_map(principal_id)
      updated = Map.put(config, key, value)
      store_config_map(principal_id, updated)
    else
      {:error, :store_unavailable}
    end
  end

  @doc """
  Store multiple settings for a user at once.

  ## Examples

      UserConfig.put_many("human_abc123", %{
        default_model: "claude-sonnet-4-5-20250514",
        default_provider: :anthropic
      })
  """
  @spec put_many(String.t(), map()) :: :ok | {:error, term()}
  def put_many(principal_id, settings) when is_binary(principal_id) and is_map(settings) do
    if available?() do
      config = load_config_map(principal_id)
      updated = Map.merge(config, settings)
      store_config_map(principal_id, updated)
    else
      {:error, :store_unavailable}
    end
  end

  @doc """
  Get a user-specific setting. Returns nil if not set.

  Does NOT cascade through app config or defaults.
  Use `get_effective/3` for cascaded resolution.
  """
  @spec get(String.t(), atom()) :: term()
  def get(principal_id, key) when is_binary(principal_id) and is_atom(key) do
    config = load_config_map(principal_id)
    Map.get(config, key)
  end

  @doc """
  Get a setting with cascaded resolution.

  Resolution order: user config → app config → provided default.

  ## Examples

      # User has no override, app config has default_model set
      UserConfig.get_effective("human_abc123", :default_model, "fallback")
      #=> value from app config or "fallback"
  """
  @spec get_effective(String.t(), atom(), term()) :: term()
  def get_effective(principal_id, key, default \\ nil) do
    # 1. User-specific setting
    case get(principal_id, key) do
      nil ->
        # 2. Application-level default
        app_defaults = Application.get_env(:arbor_agent, @app_config_key, %{})

        case Map.get(app_defaults, key) do
          nil -> default
          app_value -> app_value
        end

      user_value ->
        user_value
    end
  end

  @doc """
  Get all settings for a user as a map.
  """
  @spec get_all(String.t()) :: map()
  def get_all(principal_id) when is_binary(principal_id) do
    load_config_map(principal_id)
  end

  @doc """
  Delete a specific setting for a user.
  """
  @spec delete(String.t(), atom()) :: :ok | {:error, term()}
  def delete(principal_id, key) when is_binary(principal_id) and is_atom(key) do
    if available?() do
      config = load_config_map(principal_id)
      updated = Map.delete(config, key)
      store_config_map(principal_id, updated)
    else
      {:error, :store_unavailable}
    end
  end

  @doc """
  Delete all settings for a user.
  """
  @spec delete_all(String.t()) :: :ok
  def delete_all(principal_id) when is_binary(principal_id) do
    if available?() do
      BufferedStore.delete(principal_id, name: @store_name)
    end

    :ok
  end

  @doc """
  List all user IDs that have stored config.
  """
  @spec list_configured_users() :: [String.t()]
  def list_configured_users do
    if available?() do
      case BufferedStore.list(name: @store_name) do
        {:ok, keys} -> keys
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Check if the UserConfig store is running.
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(@store_name) != nil
  end

  # ── API Key Helpers ────────────────────────────────────────────────

  @doc """
  Get a user's API key for a specific provider.

  API keys are stored in the `:api_keys` map, keyed by provider atom.

  ## Examples

      UserConfig.get_api_key("human_abc123", :anthropic)
      #=> "sk-ant-..."
  """
  @spec get_api_key(String.t(), atom()) :: String.t() | nil
  def get_api_key(principal_id, provider) when is_atom(provider) do
    case get(principal_id, :api_keys) do
      %{} = keys -> Map.get(keys, provider)
      _ -> nil
    end
  end

  @doc """
  Set a user's API key for a specific provider.
  """
  @spec put_api_key(String.t(), atom(), String.t()) :: :ok | {:error, term()}
  def put_api_key(principal_id, provider, api_key)
      when is_atom(provider) and is_binary(api_key) do
    current_keys = get(principal_id, :api_keys) || %{}
    updated_keys = Map.put(current_keys, provider, api_key)
    put(principal_id, :api_keys, updated_keys)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp load_config_map(principal_id) do
    if available?() do
      case BufferedStore.get(principal_id, name: @store_name) do
        {:ok, raw} -> unwrap_config(raw)
        {:error, :not_found} -> %{}
        {:error, _} -> %{}
      end
    else
      %{}
    end
  end

  defp store_config_map(principal_id, config) when is_map(config) do
    record = %Record{
      id: principal_id,
      key: principal_id,
      data: config,
      metadata: %{}
    }

    BufferedStore.put(principal_id, record, name: @store_name)
  end

  # Record struct from backend (loaded from disk after restart)
  defp unwrap_config(%Record{data: data}) when is_map(data), do: data
  # Plain map from ETS (stored during current session)
  defp unwrap_config(%{} = data), do: data
end
