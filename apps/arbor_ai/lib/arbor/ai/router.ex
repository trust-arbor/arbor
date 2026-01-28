defmodule Arbor.AI.Router do
  @moduledoc """
  Routes LLM requests to the appropriate backend (API or CLI).

  The router decides whether to use the API backend (ReqLLM, paid) or
  the CLI backend (CLI agents, "free" via subscriptions) based on
  configuration and per-request options.

  ## Routing Strategies

  - `:cost_optimized` - Try CLI first, fall back to API (default)
  - `:quality_first` - Use API for important requests, CLI for bulk
  - `:cli_only` - Only use CLI backends
  - `:api_only` - Only use API backends

  ## Configuration

      config :arbor_ai,
        default_backend: :auto,       # :api, :cli, or :auto
        routing_strategy: :cost_optimized

  ## Usage

      # Auto-route (uses configured strategy)
      backend = Router.select_backend(opts)

      # Explicit backend
      backend = Router.select_backend(backend: :cli)
  """

  alias Arbor.AI.{CliImpl, Config}

  require Logger

  @type backend :: :api | :cli
  @type strategy :: :cost_optimized | :quality_first | :cli_only | :api_only

  @doc """
  Select the appropriate backend for a request.

  ## Options

  - `:backend` - Explicit backend selection (`:api`, `:cli`, or `:auto`)
  - `:strategy` - Override routing strategy for this request

  ## Returns

  `:api` or `:cli`
  """
  @spec select_backend(keyword()) :: backend()
  def select_backend(opts \\ []) do
    case Keyword.get(opts, :backend, Config.default_backend()) do
      :api ->
        :api

      :cli ->
        :cli

      :auto ->
        # Use strategy to decide
        strategy = Keyword.get(opts, :strategy, Config.routing_strategy())
        select_by_strategy(strategy, opts)
    end
  end

  @doc """
  Returns true if CLI backends should be tried before API.
  """
  @spec prefer_cli?(keyword()) :: boolean()
  def prefer_cli?(opts \\ []) do
    select_backend(opts) == :cli
  end

  @doc """
  Route and execute a generation request.

  This is a convenience function that selects the backend and
  dispatches to the appropriate implementation.
  """
  @spec route(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def route(prompt, opts \\ []) do
    backend = select_backend(opts)

    Logger.debug("Router selected backend", backend: backend)

    case backend do
      :cli ->
        CliImpl.generate_text(prompt, opts)

      :api ->
        # Delegate to the API implementation (ReqLLM path)
        Arbor.AI.generate_text_via_api(prompt, opts)
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp select_by_strategy(:cost_optimized, _opts) do
    # Prefer CLI (free) over API (paid)
    :cli
  end

  defp select_by_strategy(:quality_first, opts) do
    # Use API for important requests, CLI for bulk/simple
    if Keyword.get(opts, :important, false) do
      :api
    else
      :cli
    end
  end

  defp select_by_strategy(:cli_only, _opts) do
    :cli
  end

  defp select_by_strategy(:api_only, _opts) do
    :api
  end

  defp select_by_strategy(_unknown, _opts) do
    # Default to cost-optimized
    :cli
  end
end
