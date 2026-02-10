defmodule Arbor.Orchestrator.Human.Answer do
  @moduledoc false

  @type value :: String.t() | :yes | :no | :skipped | :timeout

  @type t :: %__MODULE__{
          value: value(),
          selected_option: map() | nil,
          text: String.t() | nil
        }

  defstruct value: :skipped, selected_option: nil, text: nil
end
