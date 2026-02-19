defmodule Arbor.Orchestrator.Authoring.Conversation do
  @moduledoc "Multi-turn conversation state for AI-assisted pipeline authoring."

  alias Arbor.Orchestrator.Authoring.SystemPrompt

  defstruct history: [], system_prompt: "", mode: :blank

  @type role :: :user | :assistant | :system
  @type message :: {role(), String.t()}

  @type t :: %__MODULE__{
          history: [message()],
          system_prompt: String.t(),
          mode: atom()
        }

  @doc "Initialize a new conversation for the given mode."
  def new(mode, opts \\ []) do
    system = Keyword.get(opts, :system_prompt, SystemPrompt.for_mode(mode))

    %__MODULE__{
      mode: mode,
      system_prompt: system,
      history: []
    }
  end

  @doc "Add a user message to the conversation."
  def add_user(%__MODULE__{} = conv, message) do
    %{conv | history: conv.history ++ [{:user, message}]}
  end

  @doc "Add an assistant response to the conversation."
  def add_assistant(%__MODULE__{} = conv, message) do
    %{conv | history: conv.history ++ [{:assistant, message}]}
  end

  @doc "Serialize the full conversation into a single prompt string for the LLM."
  def to_prompt(%__MODULE__{} = conv) do
    system_part = "SYSTEM:\n#{conv.system_prompt}\n\n"

    history_part =
      conv.history
      |> Enum.map_join("\n\n", fn
        {:user, msg} -> "USER: #{msg}"
        {:assistant, msg} -> "ASSISTANT: #{msg}"
        {:system, msg} -> "SYSTEM: #{msg}"
      end)

    system_part <> history_part
  end

  @doc "Get the number of turns in the conversation."
  def turn_count(%__MODULE__{history: h}), do: length(h)
end
