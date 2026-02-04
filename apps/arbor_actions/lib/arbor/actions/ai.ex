defmodule Arbor.Actions.AI do
  @moduledoc """
  AI/LLM operations as Jido actions.

  This module provides Jido-compatible actions for AI text generation
  and code analysis. Actions wrap the `Arbor.AI` facade and provide
  proper observability through signals.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `GenerateText` | Generate text using an LLM provider |
  | `AnalyzeCode` | Analyze code using an LLM |

  ## Examples

      # Generate text
      {:ok, result} = Arbor.Actions.AI.GenerateText.run(
        %{prompt: "What is Elixir?"},
        %{}
      )
      result.text  # => "Elixir is a dynamic, functional language..."

      # Analyze code
      {:ok, result} = Arbor.Actions.AI.AnalyzeCode.run(
        %{
          code: "def foo, do: :bar",
          question: "What does this function do?"
        },
        %{}
      )
      result.analysis  # => "This function foo/0 returns the atom :bar..."

  ## Authorization

  When using `Arbor.Actions.authorize_and_execute/4`, the capability URI
  is `arbor://actions/execute/ai.generate_text` or `arbor://actions/execute/ai.analyze_code`.
  """

  defmodule GenerateText do
    @moduledoc """
    Generate text using an LLM provider.

    Wraps the Arbor.AI facade as a Jido action for consistent
    execution and LLM tool schema generation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `prompt` | string | yes | Text prompt to send to the LLM |
    | `provider` | string | no | Provider name (uses routing if not specified) |
    | `max_tokens` | integer | no | Maximum tokens in response (default: 1000) |
    | `system_prompt` | string | no | Optional system prompt for context |
    | `temperature` | float | no | Sampling temperature (default: 0.7) |

    ## Returns

    - `text` - The generated text response
    - `provider_used` - The provider that was used
    - `model` - The model that was used
    - `usage` - Token usage information (if available)
    """

    use Jido.Action,
      name: "ai_generate_text",
      description: "Generate text using an LLM provider",
      category: "ai",
      tags: ["ai", "llm", "generate", "text"],
      schema: [
        prompt: [
          type: :string,
          required: true,
          doc: "Text prompt to send to the LLM"
        ],
        provider: [
          type: :string,
          doc: "Provider name (e.g., 'anthropic', 'openai'). Uses routing if not specified."
        ],
        max_tokens: [
          type: :integer,
          default: 1000,
          doc: "Maximum tokens in response"
        ],
        system_prompt: [
          type: :string,
          doc: "Optional system prompt for context"
        ],
        temperature: [
          type: :float,
          default: 0.7,
          doc: "Sampling temperature (0.0-1.0)"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Common.SafeAtom

    @allowed_providers [
      :anthropic,
      :openai,
      :gemini,
      :ollama,
      :lmstudio,
      :opencode,
      :openrouter,
      :qwen
    ]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{prompt: prompt} = params, _context) do
      Actions.emit_started(__MODULE__, %{prompt_length: String.length(prompt)})

      opts = build_opts(params)

      case Arbor.AI.generate_text(prompt, opts) do
        {:ok, response} ->
          result = %{
            text: response.text || "",
            provider_used: response.provider,
            model: response.model,
            usage: response[:usage] || %{}
          }

          Actions.emit_completed(__MODULE__, %{
            provider: response.provider,
            model: response.model,
            output_length: String.length(result.text)
          })

          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp build_opts(params) do
      []
      |> maybe_add(:provider, normalize_provider(params[:provider]))
      |> maybe_add(:max_tokens, params[:max_tokens])
      |> maybe_add(:system_prompt, params[:system_prompt])
      |> maybe_add(:temperature, params[:temperature])
    end

    defp normalize_provider(nil), do: nil

    defp normalize_provider(provider) when is_binary(provider) do
      case SafeAtom.to_allowed(provider, @allowed_providers) do
        {:ok, atom} -> atom
        {:error, _} -> nil
      end
    end

    defp normalize_provider(provider) when is_atom(provider), do: provider

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "AI generation failed: #{inspect(reason)}"
  end

  defmodule AnalyzeCode do
    @moduledoc """
    Analyze code using an LLM.

    Higher-level than GenerateText — formats the prompt for code analysis
    and returns structured output with analysis and suggestions.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `code` | string | yes | Code to analyze |
    | `question` | string | yes | Analysis question or task |
    | `language` | string | no | Programming language (helps LLM) |
    | `provider` | string | no | Provider name (uses routing if not specified) |
    | `max_tokens` | integer | no | Maximum tokens in response (default: 2000) |

    ## Returns

    - `analysis` - The analysis text
    - `suggestions` - List of suggestions (if any were extracted)
    - `provider_used` - The provider that was used
    - `model` - The model that was used
    """

    use Jido.Action,
      name: "ai_analyze_code",
      description: "Analyze code using an LLM",
      category: "ai",
      tags: ["ai", "llm", "code", "analyze"],
      schema: [
        code: [
          type: :string,
          required: true,
          doc: "Code to analyze"
        ],
        question: [
          type: :string,
          required: true,
          doc: "Analysis question or task"
        ],
        language: [
          type: :string,
          doc: "Programming language (e.g., 'elixir', 'python')"
        ],
        provider: [
          type: :string,
          doc: "Provider name. Uses routing if not specified."
        ],
        max_tokens: [
          type: :integer,
          default: 2000,
          doc: "Maximum tokens in response"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Common.SafeAtom

    @allowed_providers [
      :anthropic,
      :openai,
      :gemini,
      :ollama,
      :lmstudio,
      :opencode,
      :openrouter,
      :qwen
    ]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{code: code, question: question} = params, _context) do
      Actions.emit_started(__MODULE__, %{
        code_length: String.length(code),
        language: params[:language]
      })

      prompt = build_analysis_prompt(code, question, params[:language])
      opts = build_opts(params)

      case Arbor.AI.generate_text(prompt, opts) do
        {:ok, response} ->
          analysis_text = response.text || ""
          suggestions = extract_suggestions(analysis_text)

          result = %{
            analysis: analysis_text,
            suggestions: suggestions,
            provider_used: response.provider,
            model: response.model
          }

          Actions.emit_completed(__MODULE__, %{
            provider: response.provider,
            model: response.model,
            suggestions_count: length(suggestions)
          })

          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp build_analysis_prompt(code, question, language) do
      language_hint = if language, do: " (#{language})", else: ""

      """
      Analyze the following code#{language_hint}:

      ```#{language || ""}
      #{code}
      ```

      Question/Task: #{question}

      Please provide:
      1. A clear analysis addressing the question
      2. Any suggestions for improvement (if applicable)

      Format suggestions as a bulleted list starting with "- " if you have any.
      """
    end

    defp build_opts(params) do
      []
      |> maybe_add(:provider, normalize_provider(params[:provider]))
      |> maybe_add(:max_tokens, params[:max_tokens])
      |> Keyword.put(
        :system_prompt,
        "You are a code analysis assistant. Provide clear, actionable analysis."
      )
    end

    defp normalize_provider(nil), do: nil

    defp normalize_provider(provider) when is_binary(provider) do
      case SafeAtom.to_allowed(provider, @allowed_providers) do
        {:ok, atom} -> atom
        {:error, _} -> nil
      end
    end

    defp normalize_provider(provider) when is_atom(provider), do: provider

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

    defp extract_suggestions(text) do
      # Extract lines starting with "- " that look like suggestions
      text
      |> String.split(~r/\r?\n/)
      |> Enum.filter(fn line ->
        trimmed = String.trim(line)
        String.starts_with?(trimmed, "- ") and String.length(trimmed) > 3
      end)
      |> Enum.map(fn line ->
        line
        |> String.trim()
        |> String.trim_leading("- ")
      end)
    end

    defp format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
    defp format_error(reason), do: "Code analysis failed: #{inspect(reason)}"
  end
end
