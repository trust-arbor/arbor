defmodule Arbor.Orchestrator.AgentLoop.Session do
  @moduledoc false

  alias Arbor.Orchestrator.AgentLoop.Config

  @type message :: %{
          role: :system | :user | :assistant | :tool,
          content: String.t(),
          metadata: map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          messages: [message()],
          turn: non_neg_integer(),
          config: Config.t(),
          status: :running | :completed | :failed,
          result: map() | nil
        }

  defstruct id: "",
            messages: [],
            turn: 0,
            config: %Config{},
            status: :running,
            result: nil

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      id:
        Keyword.get(
          opts,
          :id,
          "session_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
        ),
      messages: Keyword.get(opts, :messages, []),
      config: Keyword.get(opts, :config, %Config{})
    }
  end
end
