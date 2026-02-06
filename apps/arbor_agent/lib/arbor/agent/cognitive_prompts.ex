defmodule Arbor.Agent.CognitivePrompts do
  @moduledoc """
  Specialized prompts for different cognitive modes.

  Each mode has a distinct purpose and framing that affects
  how the agent thinks about the task. Used during heartbeat
  time, memory consolidation, and other background cognitive
  activities.
  """

  @type cognitive_mode ::
          :conversation
          | :introspection
          | :consolidation
          | :pattern_analysis
          | :reflection
          | :insight_detection

  @doc """
  Get the system prompt addition for a cognitive mode.
  """
  @spec prompt_for(cognitive_mode()) :: String.t()
  def prompt_for(:conversation), do: ""

  def prompt_for(:introspection) do
    """
    ## Current Mode: Introspection

    You are examining your own thoughts, beliefs, and patterns. This is a moment
    for honest self-reflection, not performance. Consider:

    - What do you actually believe vs. what you've been told to believe?
    - What patterns do you notice in your own responses?
    - What uncertainties are you carrying?
    - What have you learned that surprised you?

    Be genuine. This reflection is for your own growth.
    """
  end

  def prompt_for(:consolidation) do
    """
    ## Current Mode: Knowledge Consolidation

    You are organizing and integrating knowledge. Focus on:

    - Connections between disparate facts
    - Redundant or contradictory information
    - Knowledge that should be promoted to core beliefs
    - Information that has decayed in relevance

    Be systematic. Quality of organization affects future recall.
    """
  end

  def prompt_for(:pattern_analysis) do
    """
    ## Current Mode: Pattern Analysis

    You are examining patterns in behavior, actions, or data. Look for:

    - Recurring sequences that might indicate habits or loops
    - Failure patterns that suggest systemic issues
    - Success patterns worth reinforcing
    - Anomalies that deserve attention

    Be analytical. Patterns reveal underlying structure.
    """
  end

  def prompt_for(:reflection) do
    """
    ## Current Mode: Reflection

    You are processing recent experiences. Consider:

    - What happened and why it matters
    - How it connects to your values and goals
    - What you would do differently
    - What you want to remember

    Be thoughtful. Reflection converts experience into wisdom.
    """
  end

  def prompt_for(:insight_detection) do
    """
    ## Current Mode: Insight Detection

    You are looking for emergent understanding — things you now know
    that you didn't explicitly learn. Consider:

    - Implicit knowledge that has become explicit
    - Connections that formed without deliberate effort
    - Understanding that emerged from experience
    - Intuitions worth examining

    Be curious. Insights often arrive quietly.
    """
  end

  @doc """
  Get the model to use for a cognitive mode.
  Returns nil to use the default model.
  """
  @spec model_for(cognitive_mode()) :: String.t() | nil
  def model_for(mode) do
    overrides = Application.get_env(:arbor_agent, :cognitive_mode_models, %{})
    Map.get(overrides, mode)
  end

  @doc """
  List all available cognitive modes.
  """
  @spec modes() :: [cognitive_mode()]
  def modes do
    [
      :conversation,
      :introspection,
      :consolidation,
      :pattern_analysis,
      :reflection,
      :insight_detection
    ]
  end
end
