defmodule Arbor.AI.BackendRegistry do
  @moduledoc """
  Registry for LLM backend availability detection with lazy caching.

  This module tracks which LLM backends are available (installed, authenticated)
  and caches the results to avoid repeated checks on every call.

  ## Features

  - Lazy detection: Only checks when first accessed
  - ETS caching: Fast lookups with configurable TTL
  - Authentication detection: Checks for required API keys

  ## Usage

      # Check if a backend is available
      BackendRegistry.available?(:claude_cli)
      #=> :available | :unavailable | :not_installed

      # Get all available backends
      BackendRegistry.available_backends()
      #=> [:claude_cli, :gemini_cli, :anthropic_api]

      # Force refresh of cache
      BackendRegistry.refresh(:claude_cli)
      BackendRegistry.refresh_all()

  ## Backend Types

  - CLI backends: claude, codex, gemini, qwen, opencode
  - API backends: anthropic, openai, google (via env vars)
  - Server backends: lmstudio (local HTTP)
  """

  use GenServer
  require Logger

  alias Arbor.AI.ShellAdapter

  @table :arbor_ai_backend_status
  # 5 minutes
  @default_ttl_ms 300_000

  @type backend :: atom()
  @type status :: :available | :unavailable | :not_installed | :checking
  @type backend_info :: %{
          status: status(),
          checked_at: integer(),
          version: String.t() | nil,
          path: String.t() | nil
        }

  # CLI backend configurations
  @cli_backends %{
    claude_cli: %{cmd: "claude", version_args: ["--version"]},
    codex_cli: %{cmd: "codex", version_args: ["--version"]},
    gemini_cli: %{cmd: "gemini", version_args: ["--version"]},
    qwen_cli: %{cmd: "qwen", version_args: ["--version"]},
    opencode_cli: %{cmd: "opencode", version_args: ["--version"]}
  }

  # API backend configurations
  @api_backends %{
    anthropic_api: %{env_key: "ANTHROPIC_API_KEY"},
    openai_api: %{env_key: "OPENAI_API_KEY"},
    google_api: %{env_key: "GOOGLE_API_KEY"},
    openrouter: %{env_key: "OPENROUTER_API_KEY"}
  }

  # Local server backend configurations
  @server_backends %{
    lmstudio: %{
      health_url: "http://localhost:1234/v1/models"
    }
  }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the BackendRegistry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a backend is available.

  Returns cached result if available and not expired, otherwise performs check.

  ## Returns
  - `:available` - Backend is installed and ready to use
  - `:unavailable` - Backend exists but is not properly configured
  - `:not_installed` - Backend command/library not found
  """
  @spec available?(backend()) :: status()
  def available?(backend) do
    ensure_started()

    case get_cached(backend) do
      {:ok, info} ->
        info.status

      :miss ->
        check_and_cache(backend)
    end
  end

  @doc """
  Gets detailed information about a backend.
  """
  @spec get_info(backend()) :: backend_info() | nil
  def get_info(backend) do
    ensure_started()

    case get_cached(backend) do
      {:ok, info} ->
        info

      :miss ->
        check_and_cache(backend)

        case get_cached(backend) do
          {:ok, info} -> info
          :miss -> nil
        end
    end
  end

  @doc """
  Returns all available backends.
  """
  @spec available_backends() :: [backend()]
  def available_backends do
    ensure_started()

    all_backends()
    |> Enum.filter(fn backend -> available?(backend) == :available end)
  end

  @doc """
  Returns all CLI backends (for code agents).
  """
  @spec cli_backends() :: [backend()]
  def cli_backends, do: Map.keys(@cli_backends)

  @doc """
  Returns all API backends.
  """
  @spec api_backends() :: [backend()]
  def api_backends, do: Map.keys(@api_backends)

  @doc """
  Returns all local server backends.
  """
  @spec server_backends() :: [backend()]
  def server_backends, do: Map.keys(@server_backends)

  @doc """
  Returns all known backends (available or not).
  """
  @spec all_backends() :: [backend()]
  def all_backends do
    cli_backends() ++ api_backends() ++ server_backends()
  end

  @doc """
  Gets the command name for a CLI backend.
  """
  @spec get_command(backend()) :: String.t() | nil
  def get_command(backend) do
    case @cli_backends[backend] do
      %{cmd: cmd} -> cmd
      _ -> nil
    end
  end

  @doc """
  Forces a refresh of a specific backend's status.
  """
  @spec refresh(backend()) :: status()
  def refresh(backend) do
    ensure_started()
    do_check(backend)
  end

  @doc """
  Forces a refresh of all backends.
  """
  @spec refresh_all() :: [{backend(), status()}]
  def refresh_all do
    ensure_started()

    all_backends()
    |> Enum.map(fn backend ->
      {backend, do_check(backend)}
    end)
  end

  @doc """
  Gets the cache TTL in milliseconds.
  """
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms do
    Application.get_env(:arbor_ai, :backend_registry_ttl_ms, @default_ttl_ms)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("BackendRegistry starting, creating ETS table")
    # Create ETS table for caching
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    Logger.info("BackendRegistry started successfully")
    {:ok, %{table: table}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        # Start if not running (useful for scripts/tests)
        {:ok, _} = start_link()

      _pid ->
        :ok
    end
  end

  defp get_cached(backend) do
    case :ets.lookup(@table, backend) do
      [{^backend, info}] ->
        if info.checked_at + ttl_ms() > System.monotonic_time(:millisecond) do
          {:ok, info}
        else
          # Expired
          :miss
        end

      [] ->
        :miss
    end
  rescue
    # Table doesn't exist
    ArgumentError -> :miss
  end

  defp check_and_cache(backend) do
    status = do_check(backend)
    status
  end

  defp do_check(backend) do
    info =
      cond do
        Map.has_key?(@cli_backends, backend) ->
          check_cli_backend(@cli_backends[backend])

        Map.has_key?(@api_backends, backend) ->
          check_api_backend(@api_backends[backend])

        Map.has_key?(@server_backends, backend) ->
          check_server_backend(@server_backends[backend])

        true ->
          %{status: :not_installed, checked_at: now(), version: nil, path: nil}
      end

    # Cache the result
    try do
      :ets.insert(@table, {backend, info})
    rescue
      # Table doesn't exist, skip caching
      ArgumentError -> :ok
    end

    Logger.debug("Backend check", backend: backend, status: info.status)
    info.status
  end

  defp check_cli_backend(config) do
    case find_cli_command(config.cmd) do
      {:ok, path} ->
        # Skip version check - if 'which' finds it, assume it's available
        %{status: :available, checked_at: now(), version: nil, path: path}

      :not_found ->
        %{status: :not_installed, checked_at: now(), version: nil, path: nil}
    end
  end

  defp check_api_backend(config) do
    if System.get_env(config.env_key) do
      %{status: :available, checked_at: now(), version: nil, path: nil}
    else
      %{status: :unavailable, checked_at: now(), version: nil, path: nil}
    end
  end

  defp check_server_backend(config) do
    # Check if local server is running by pinging health endpoint
    case Req.get(config.health_url, receive_timeout: 2_000) do
      {:ok, %{status: 200}} ->
        %{status: :available, checked_at: now(), version: nil, path: config.health_url}

      _ ->
        %{status: :unavailable, checked_at: now(), version: nil, path: nil}
    end
  rescue
    # Connection refused, timeout, etc.
    _ -> %{status: :unavailable, checked_at: now(), version: nil, path: nil}
  end

  defp find_cli_command(cmd) do
    # Use `which` to find commands in PATH
    case ShellAdapter.cmd("which", [cmd], stderr_to_stdout: true) do
      {path, 0} -> {:ok, String.trim(path)}
      _ -> :not_found
    end
  rescue
    _ -> :not_found
  end

  defp now, do: System.monotonic_time(:millisecond)
end
