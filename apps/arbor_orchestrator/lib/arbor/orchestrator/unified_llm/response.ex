defmodule Arbor.Orchestrator.UnifiedLLM.Response do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.ContentPart

  @type finish_reason :: :stop | :length | :tool_calls | :content_filter | :error | :other

  @type t :: %__MODULE__{
          text: String.t(),
          finish_reason: finish_reason(),
          content_parts: [ContentPart.part()],
          usage: map(),
          warnings: [String.t()],
          raw: map() | nil
        }

  defstruct text: "", finish_reason: :stop, content_parts: [], usage: %{}, warnings: [], raw: nil
end
