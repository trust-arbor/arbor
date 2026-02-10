defmodule Arbor.Orchestrator.UnifiedLLM.Message do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.ContentPart

  @type role :: :system | :developer | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | [ContentPart.part()],
          metadata: map()
        }

  defstruct role: :user, content: "", metadata: %{}

  @spec new(role(), String.t() | [ContentPart.part()], map()) :: t()
  def new(role, content, metadata \\ %{}) do
    %__MODULE__{role: role, content: content, metadata: metadata}
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    ContentPart.text_content(content)
  end
end
