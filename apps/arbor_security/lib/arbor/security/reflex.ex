defmodule Arbor.Security.Reflex do
  @moduledoc """
  Instant safety checks that fire before capability authorization.

  Reflexes are fast pattern-based checks for obviously dangerous actions.
  They're checked before capabilities to fail fast on dangerous requests.

  ## Design Philosophy

  Reflexes are the first line of defense — they catch obvious mistakes before
  expensive authorization checks. They're:

  - **Fast** — Pattern matching, no database lookups
  - **Simple** — One pattern, one response
  - **Composable** — Multiple reflexes can be combined

  ## Built-in Reflexes

  Built-in reflexes protect against common dangerous patterns:

  | ID | Type | Response | Description |
  |----|------|----------|-------------|
  | `rm_rf_root` | pattern | block | `rm -rf /` and variants |
  | `sudo_su` | pattern | block | `sudo`/`su` commands |
  | `ssh_private_keys` | path | block | `~/.ssh/id_*` access |
  | `env_files` | path | warn | `.env*` file access |
  | `ssrf_metadata` | pattern | block | Cloud metadata (169.254.x.x) |

  See `Arbor.Security.Reflex.Builtin` for the complete list.

  ## Custom Reflexes

      # Register a project-specific reflex
      {:ok, reflex} = Arbor.Contracts.Security.Reflex.pattern(
        "block_prod_db",
        ~r/production.*database/i,
        :block,
        message: "Cannot access production database"
      )
      :ok = Arbor.Security.Reflex.register(:block_prod_db, reflex)

  ## Check Results

  - `:ok` — No reflex triggered, proceed to capability check
  - `{:blocked, reflex, message}` — Reflex blocked the action
  - `{:warned, warnings}` — Reflexes issued warnings but allowed

  ## Integration

  Reflexes are automatically checked by `Arbor.Security.authorize/3` before
  capability verification. You can also check directly:

      case Arbor.Security.Reflex.check(%{command: "rm -rf /"}) do
        :ok -> proceed_with_authorization()
        {:blocked, reflex, msg} -> deny_immediately(msg)
        {:warned, warnings} -> log_warnings_and_proceed(warnings)
      end
  """

  alias Arbor.Contracts.Security.Reflex, as: ReflexContract
  alias Arbor.Security.Reflex.Registry
  alias Arbor.Signals

  @type check_context :: %{
          optional(:command) => String.t(),
          optional(:path) => String.t(),
          optional(:resource) => String.t(),
          optional(:action) => atom(),
          optional(:url) => String.t(),
          optional(:data) => term()
        }

  @type check_result ::
          :ok
          | {:blocked, ReflexContract.t(), String.t()}
          | {:warned, [{ReflexContract.t(), String.t()}]}

  # ── Public API ──

  @doc """
  Check all enabled reflexes against a context.

  The context is a map that can contain various fields depending on
  what is being checked:

  - `:command` — Shell command string
  - `:path` — File path being accessed
  - `:resource` — Resource URI
  - `:action` — Action being performed
  - `:url` — URL being accessed
  - `:data` — Arbitrary data for custom reflexes

  ## Examples

      # Check a shell command
      Arbor.Security.Reflex.check(%{command: "rm -rf /"})
      #=> {:blocked, %Reflex{id: "rm_rf_root", ...}, "Blocked: recursive delete..."}

      # Check a file path
      Arbor.Security.Reflex.check(%{path: "~/.ssh/id_rsa"})
      #=> {:blocked, %Reflex{id: "ssh_private_keys", ...}, "Blocked: access to SSH..."}

      # Check a URL
      Arbor.Security.Reflex.check(%{url: "http://169.254.169.254/latest/meta-data/"})
      #=> {:blocked, %Reflex{id: "ssrf_metadata", ...}, "Blocked: request to cloud..."}

  """
  @spec check(check_context()) :: check_result()
  def check(context) when is_map(context) do
    reflexes = Registry.list(enabled_only: true)
    {blocked, warnings} = evaluate_reflexes(reflexes, context)
    build_result(blocked, warnings)
  end

  @doc """
  Check if a single reflex matches the given context.

  Useful for testing individual reflexes.
  """
  @spec matches?(ReflexContract.t(), check_context()) :: boolean()
  def matches?(%ReflexContract{} = reflex, context) do
    ReflexContract.matches?(reflex, context)
  end

  @doc """
  Register a custom reflex.

  ## Options

  - `:force` — Overwrite existing reflex with same ID (default: false)

  ## Examples

      reflex = Reflex.pattern("my_check", ~r/dangerous/, :block)
      :ok = Arbor.Security.Reflex.register(:my_check, reflex)
  """
  @spec register(atom(), ReflexContract.t(), keyword()) :: :ok | {:error, :already_exists}
  def register(id, %ReflexContract{} = reflex, opts \\ []) do
    case Registry.register(id, reflex, opts) do
      :ok ->
        emit_reflex_registered(id, reflex)
        :ok

      error ->
        error
    end
  end

  @doc """
  Unregister a reflex by ID.

  Built-in reflexes can be unregistered if needed, but this is not recommended.

  ## Examples

      :ok = Arbor.Security.Reflex.unregister(:my_check)
  """
  @spec unregister(atom()) :: :ok | {:error, :not_found}
  def unregister(id) do
    case Registry.unregister(id) do
      :ok ->
        emit_reflex_unregistered(id)
        :ok

      error ->
        error
    end
  end

  @doc """
  List all registered reflexes.

  ## Options

  - `:enabled_only` — Only return enabled reflexes (default: false)
  - `:sorted` — Sort by priority, highest first (default: true)
  """
  @spec list(keyword()) :: [ReflexContract.t()]
  def list(opts \\ []) do
    Registry.list(opts)
  end

  @doc """
  Get a reflex by ID.
  """
  @spec get(atom()) :: {:ok, ReflexContract.t()} | {:error, :not_found}
  def get(id) do
    Registry.get(id)
  end

  @doc """
  Enable or disable a reflex.
  """
  @spec set_enabled(atom(), boolean()) :: :ok | {:error, :not_found}
  def set_enabled(id, enabled) when is_boolean(enabled) do
    case Registry.get(id) do
      {:ok, reflex} ->
        updated =
          if enabled do
            ReflexContract.enable(reflex)
          else
            ReflexContract.disable(reflex)
          end

        Registry.register(id, updated, force: true)

      error ->
        error
    end
  end

  @doc """
  Get reflex statistics.
  """
  @spec stats() :: map()
  def stats do
    Registry.stats()
  end

  # ── Private Functions ──

  # Evaluate all reflexes against the context, collecting blocks and warnings
  defp evaluate_reflexes(reflexes, context) do
    Enum.reduce(reflexes, {nil, []}, fn reflex, acc ->
      evaluate_single_reflex(reflex, context, acc)
    end)
  end

  # Skip evaluation if already blocked
  defp evaluate_single_reflex(_reflex, _context, {blocked, warnings}) when blocked != nil do
    {blocked, warnings}
  end

  # Evaluate a single reflex
  defp evaluate_single_reflex(reflex, context, {nil, warnings}) do
    if matches?(reflex, context) do
      handle_reflex_match(reflex, context, warnings)
    else
      {nil, warnings}
    end
  end

  # Handle a reflex that matched
  defp handle_reflex_match(%{response: :block} = reflex, _context, warnings) do
    {reflex, warnings}
  end

  defp handle_reflex_match(%{response: :warn} = reflex, _context, warnings) do
    message = reflex.message || "Warning: reflex #{reflex.id} triggered"
    {nil, [{reflex, message} | warnings]}
  end

  defp handle_reflex_match(%{response: :log} = reflex, context, warnings) do
    emit_reflex_logged(reflex, context)
    {nil, warnings}
  end

  # Build the final result from evaluation
  defp build_result(blocked, _warnings) when blocked != nil do
    message = blocked.message || "Blocked by reflex: #{blocked.id}"
    {:blocked, blocked, message}
  end

  defp build_result(nil, warnings) when warnings != [] do
    {:warned, Enum.reverse(warnings)}
  end

  defp build_result(nil, []) do
    :ok
  end

  # ── Signal Emissions ──

  defp emit_reflex_registered(id, reflex) do
    Signals.emit(:security, :reflex_registered, %{
      reflex_id: id,
      reflex_name: reflex.name,
      reflex_type: reflex.type,
      response: reflex.response
    })
  end

  defp emit_reflex_unregistered(id) do
    Signals.emit(:security, :reflex_unregistered, %{reflex_id: id})
  end

  defp emit_reflex_logged(reflex, context) do
    Signals.emit(:security, :reflex_logged, %{
      reflex_id: reflex.id,
      reflex_name: reflex.name,
      context: sanitize_context(context)
    })
  end

  # Don't include potentially sensitive data in signals
  defp sanitize_context(context) do
    context
    |> Map.take([:action, :resource])
    |> Map.put(:has_command, Map.has_key?(context, :command))
    |> Map.put(:has_path, Map.has_key?(context, :path))
    |> Map.put(:has_url, Map.has_key?(context, :url))
  end
end
