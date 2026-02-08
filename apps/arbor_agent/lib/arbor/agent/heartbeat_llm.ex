defmodule Arbor.Agent.HeartbeatLLM do
  @moduledoc """
  LLM think cycle for heartbeat processing.

  Every heartbeat triggers an LLM call — matching old arbor's SeedServer
  pattern where `@default_think_interval` was 30s and every think cycle
  made an LLM call (no cooldown).

  Uses `HeartbeatPrompt` to build structured prompts and `HeartbeatResponse`
  to parse structured JSON responses.

  Routes through `Arbor.AI.generate_text/2` with OpenRouter (free model)
  for fast, lightweight heartbeat thinking without spawning CLI subprocesses.
  """

  alias Arbor.Agent.{CognitivePrompts, HeartbeatPrompt, HeartbeatResponse}

  require Logger

  @doc """
  Run a think cycle during heartbeat. Called on every heartbeat.

  Builds a structured prompt, calls `Arbor.AI.generate_text/2`,
  and parses the response.

  Returns `{:ok, parsed_response}` or `{:error, reason}`.
  """
  @spec think(map(), keyword()) :: {:ok, HeartbeatResponse.parsed()} | {:error, term()}
  def think(state, opts \\ []) do
    prompt = HeartbeatPrompt.build_prompt(state)
    system = HeartbeatPrompt.system_prompt(state)

    model = Keyword.get(opts, :model, heartbeat_model())
    provider = Keyword.get(opts, :provider, heartbeat_provider())

    ai_opts = [
      model: model,
      provider: provider,
      max_tokens: 1500,
      backend: :api,
      system_prompt: system
    ]

    case call_ai(prompt, ai_opts) do
      {:ok, %{text: text, usage: usage}} ->
        parsed = HeartbeatResponse.parse(text)
        {:ok, Map.put(parsed, :usage, usage)}

      {:ok, %{text: text} = response} ->
        parsed = HeartbeatResponse.parse(text)
        usage = response[:usage] || %{input_tokens: 0, output_tokens: 0}
        {:ok, Map.put(parsed, :usage, usage)}

      {:ok, response} when is_map(response) ->
        text = response[:text] || response["text"] || ""
        parsed = HeartbeatResponse.parse(text)
        usage = response[:usage] || %{input_tokens: 0, output_tokens: 0}
        {:ok, Map.put(parsed, :usage, usage)}

      {:error, reason} ->
        Logger.debug("Heartbeat LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Run a lighter cognitive cycle for idle periods.

  Uses introspection or consolidation mode with lower stakes.
  Only runs when no pending user messages (idle reflection).
  Probability-gated via `idle_reflection_chance`.
  """
  @spec idle_think(map(), keyword()) :: {:ok, HeartbeatResponse.parsed()} | {:error, term()}
  def idle_think(state, opts \\ []) do
    # Pick a random idle cognitive mode
    mode =
      Enum.random([:introspection, :reflection, :pattern_analysis, :insight_detection])

    state = Map.put(state, :cognitive_mode, mode)

    # Use a cheaper model for idle thinking
    idle_model =
      CognitivePrompts.model_for(mode) ||
        Keyword.get(opts, :model, idle_heartbeat_model())

    think(state, Keyword.merge(opts, model: idle_model))
  end

  # -- Private --

  defp call_ai(prompt, opts) do
    if ai_available?() do
      Arbor.AI.generate_text(prompt, opts)
    else
      {:error, :ai_unavailable}
    end
  rescue
    e ->
      {:error, {:ai_exception, Exception.message(e)}}
  catch
    :exit, reason ->
      {:error, {:ai_exit, reason}}
  end

  defp ai_available? do
    Code.ensure_loaded?(Arbor.AI) and
      function_exported?(Arbor.AI, :generate_text, 2)
  end

  defp heartbeat_model do
    Application.get_env(:arbor_agent, :heartbeat_model, "arcee-ai/trinity-large-preview:free")
  end

  defp idle_heartbeat_model do
    Application.get_env(
      :arbor_agent,
      :idle_heartbeat_model,
      "arcee-ai/trinity-large-preview:free"
    )
  end

  defp heartbeat_provider do
    Application.get_env(:arbor_agent, :heartbeat_provider, :openrouter)
  end
end
