defmodule Arbor.Orchestrator.Human.Question do
  @moduledoc false

  @type question_type ::
          :single_select
          | :multi_select
          | :free_text
          | :confirm
          | :multiple_choice
          | :yes_no
          | :freeform
          | :confirmation

  @type option :: %{key: String.t(), label: String.t(), to: String.t()}

  @type t :: %__MODULE__{
          text: String.t(),
          type: question_type(),
          options: [option()],
          stage: String.t(),
          default: String.t() | nil,
          timeout_seconds: float() | nil,
          metadata: map()
        }

  defstruct text: "",
            type: :multiple_choice,
            options: [],
            stage: "",
            default: nil,
            timeout_seconds: nil,
            metadata: %{}
end
