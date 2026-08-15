defmodule Arbor.Contracts.API.AI do
  @moduledoc """
  Contract for LLM provider implementations.

  Defines the interface for AI text generation that can be used
  by evaluators and other components requiring LLM capabilities.

  ## Implementation

  Implementations should wrap an underlying LLM client (like ReqLLM)
  and provide a consistent interface with structured responses.

  ## Example

      defmodule MyApp.AI do
        @behaviour Arbor.Contracts.API.AI

        @impl true
        def generate_text(prompt, opts) do
          # Call your LLM provider
          {:ok, %{text: "...", usage: %{...}, ...}}
        end
      end
  """

  @typedoc "Token usage information from LLM response"
  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @typedoc "Structured response from LLM generation"
  @type result :: %{
          text: String.t(),
          usage: usage(),
          model: String.t(),
          provider: atom()
        }

  @typedoc "Options for text generation"
  @type opts :: [
          provider: atom(),
          model: String.t(),
          system_prompt: String.t(),
          max_tokens: pos_integer(),
          temperature: float(),
          timeout: pos_integer()
        ]

  @doc """
  Generate text using an LLM.

  ## Parameters

    * `prompt` - The user prompt to send to the LLM
    * `opts` - Options for generation

  ## Options

    * `:provider` - LLM provider (e.g., `:anthropic`, `:openai`). Default: `:anthropic`
    * `:model` - Model identifier. Default: implementation-specific
    * `:system_prompt` - System message to prepend
    * `:max_tokens` - Maximum tokens to generate. Default: 1024
    * `:temperature` - Randomness (0.0-2.0). Default: 0.7
    * `:timeout` - Request timeout in ms. Default: 60_000

  ## Returns

    * `{:ok, result}` - Successful generation with text and metadata
    * `{:error, term()}` - Generation failed
  """
  @callback generate_text(prompt :: String.t(), opts :: opts()) ::
              {:ok, result()} | {:error, term()}
end
