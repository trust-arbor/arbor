defmodule Arbor.AI.Config do
  @moduledoc """
  Configuration for Arbor.AI.

  Provides application-level configuration for LLM defaults.

  ## Configuration

      config :arbor_ai,
        default_provider: :anthropic,
        default_model: "claude-sonnet-4-5-20250514",
        timeout: 60_000
  """

  @app :arbor_ai

  @doc """
  Default LLM provider.

  Default: `:anthropic`
  """
  @spec default_provider() :: atom()
  def default_provider do
    Application.get_env(@app, :default_provider, :anthropic)
  end

  @doc """
  Default model for the default provider.

  Default: `"claude-sonnet-4-5-20250514"`
  """
  @spec default_model() :: String.t()
  def default_model do
    Application.get_env(@app, :default_model, "claude-sonnet-4-5-20250514")
  end

  @doc """
  Default timeout for LLM requests in milliseconds.

  Default: `60_000` (60 seconds)
  """
  @spec timeout() :: pos_integer()
  def timeout do
    Application.get_env(@app, :timeout, 60_000)
  end

  @doc """
  Maximum retries for transient LLM errors.

  Default: `2`
  """
  @spec max_retries() :: non_neg_integer()
  def max_retries do
    Application.get_env(@app, :max_retries, 2)
  end
end
