defmodule Arbor.AI.BackendTrust do
  @moduledoc """
  Trust levels for LLM backends.

  Provides pure functions for trust-based filtering and sorting of backends.
  Trust levels indicate how much we trust the backend for sensitive operations.

  ## Trust Levels

  - `:highest` - Local models (LMStudio, Ollama) - data never leaves machine
  - `:high` - Major providers with strong privacy policies (Anthropic, OpenCode)
  - `:medium` - Established providers (OpenAI, Gemini)
  - `:low` - Third-party aggregators or less established (Qwen, OpenRouter)

  ## Configuration

  Default trust levels can be overridden via application config:

      config :arbor_ai, :backend_trust_levels, %{
        lmstudio: :highest,
        ollama: :highest,
        anthropic: :high,
        opencode: :high,
        openai: :medium,
        gemini: :medium,
        qwen: :low,
        openrouter: :low
      }

  ## Usage

      # Get trust level for a backend
      BackendTrust.level(:anthropic)
      #=> :high

      # Check if backend meets minimum trust
      BackendTrust.meets_minimum?(:anthropic, :high)
      #=> true

      # Sort backends by trust (highest first)
      BackendTrust.sort_by_trust([{:openai, "gpt-4"}, {:anthropic, "claude"}])
      #=> [{:anthropic, "claude"}, {:openai, "gpt-4"}]
  """

  @type trust_level :: :highest | :high | :medium | :low

  # Trust level ordering (highest trust first)
  @trust_order [:highest, :high, :medium, :low]

  # Default trust levels
  @default_trust_levels %{
    lmstudio: :highest,
    ollama: :highest,
    anthropic: :high,
    opencode: :high,
    openai: :medium,
    gemini: :medium,
    qwen: :low,
    openrouter: :low
  }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Get trust level for a backend.

  Returns `:low` for unknown backends (conservative default).

  ## Examples

      iex> BackendTrust.level(:anthropic)
      :high

      iex> BackendTrust.level(:lmstudio)
      :highest

      iex> BackendTrust.level(:unknown_backend)
      :low
  """
  @spec level(atom()) :: trust_level()
  def level(backend) when is_atom(backend) do
    trust_levels()
    |> Map.get(backend, :low)
  end

  @doc """
  Check if backend meets minimum trust requirement.

  The `:any` trust level matches all backends.

  ## Examples

      iex> BackendTrust.meets_minimum?(:anthropic, :high)
      true

      iex> BackendTrust.meets_minimum?(:qwen, :high)
      false

      iex> BackendTrust.meets_minimum?(:qwen, :any)
      true
  """
  @spec meets_minimum?(atom(), trust_level() | :any) :: boolean()
  def meets_minimum?(_backend, :any), do: true

  def meets_minimum?(backend, minimum) when is_atom(backend) do
    backend_level = level(backend)
    compare(backend_level, minimum) in [:gt, :eq]
  end

  @doc """
  Sort backend+model pairs by trust level (highest first).

  Within the same trust level, preserves original order.

  ## Examples

      iex> BackendTrust.sort_by_trust([{:openai, "gpt-4"}, {:anthropic, "claude"}, {:lmstudio, "local"}])
      [{:lmstudio, "local"}, {:anthropic, "claude"}, {:openai, "gpt-4"}]
  """
  @spec sort_by_trust([{atom(), term()}]) :: [{atom(), term()}]
  def sort_by_trust(backend_model_pairs) when is_list(backend_model_pairs) do
    Enum.sort_by(backend_model_pairs, fn {backend, _model} ->
      trust_rank(level(backend))
    end)
  end

  @doc """
  Compare two trust levels.

  Returns `:gt` if `a` is higher trust than `b`, `:eq` if equal, `:lt` if lower.

  ## Examples

      iex> BackendTrust.compare(:highest, :high)
      :gt

      iex> BackendTrust.compare(:medium, :medium)
      :eq

      iex> BackendTrust.compare(:low, :high)
      :lt
  """
  @spec compare(trust_level(), trust_level()) :: :gt | :eq | :lt
  def compare(a, b) when a == b, do: :eq

  def compare(a, b) do
    rank_a = trust_rank(a)
    rank_b = trust_rank(b)

    cond do
      rank_a < rank_b -> :gt
      rank_a > rank_b -> :lt
      true -> :eq
    end
  end

  @doc """
  Get all configured trust levels.

  Returns the merged result of defaults and any application config overrides.
  """
  @spec trust_levels() :: %{atom() => trust_level()}
  def trust_levels do
    config_levels = Application.get_env(:arbor_ai, :backend_trust_levels, %{})
    Map.merge(@default_trust_levels, config_levels)
  end

  @doc """
  Get the trust order (highest to lowest).
  """
  @spec trust_order() :: [trust_level()]
  def trust_order, do: @trust_order

  # ===========================================================================
  # Data-Visibility Capabilities (Sensitivity Routing)
  # ===========================================================================

  @type sensitivity :: :public | :internal | :confidential | :restricted

  # Default data-visibility capabilities per backend.
  # Local providers can see everything; cloud providers are progressively limited.
  @default_capabilities %{
    lmstudio: [:public, :internal, :confidential, :restricted],
    ollama: [:public, :internal, :confidential, :restricted],
    anthropic: [:public, :internal, :confidential],
    opencode: [:public, :internal, :confidential],
    openai: [:public, :internal],
    gemini: [:public, :internal],
    qwen: [:public],
    openrouter: [:public]
  }

  @doc """
  Check if a backend can handle data at the given sensitivity level.

  Returns `true` if the backend's data-visibility capabilities include
  the specified sensitivity. Unknown backends default to `:public` only.

  ## Examples

      iex> BackendTrust.can_see?(:lmstudio, :restricted)
      true

      iex> BackendTrust.can_see?(:openai, :restricted)
      false

      iex> BackendTrust.can_see?(:openai, :internal)
      true
  """
  @spec can_see?(atom(), sensitivity()) :: boolean()
  def can_see?(backend, sensitivity) when is_atom(backend) and is_atom(sensitivity) do
    sensitivity in data_capabilities(backend)
  end

  @doc """
  Get the list of sensitivity levels a backend can handle.

  Returns the backend's configured data-visibility capabilities.
  Unknown backends default to `[:public]` only.

  ## Examples

      iex> BackendTrust.data_capabilities(:lmstudio)
      [:public, :internal, :confidential, :restricted]

      iex> BackendTrust.data_capabilities(:qwen)
      [:public]
  """
  @spec data_capabilities(atom()) :: [sensitivity()]
  def data_capabilities(backend) when is_atom(backend) do
    capabilities()
    |> Map.get(backend, [:public])
  end

  @doc """
  Get all configured backend capabilities.

  Returns the merged result of defaults and any application config overrides.
  """
  @spec capabilities() :: %{atom() => [sensitivity()]}
  def capabilities do
    config_caps = Application.get_env(:arbor_ai, :backend_capabilities, %{})
    Map.merge(@default_capabilities, config_caps)
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  # Lower rank = higher trust
  defp trust_rank(:highest), do: 0
  defp trust_rank(:high), do: 1
  defp trust_rank(:medium), do: 2
  defp trust_rank(:low), do: 3
  defp trust_rank(_), do: 4
end
