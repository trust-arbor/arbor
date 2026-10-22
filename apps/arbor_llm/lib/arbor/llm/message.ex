defmodule Arbor.LLM.Message do
  @moduledoc false

  alias Arbor.LLM.ContentPart

  @type role :: :system | :developer | :user | :assistant | :tool | :summary

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

  @doc """
  Map an Arbor message role to a role every chat-completions or Responses
  provider accepts. Synthetic compaction summaries use `:summary` in Arbor and
  become `:system` on the wire so they are never a user turn.
  """
  @spec provider_role(role() | String.t()) :: :system | :user | :assistant | :tool
  def provider_role(role)
      when role in [:summary, :developer, :system, "summary", "developer", "system"],
      do: :system

  def provider_role(role) when role in [:user, "user"], do: :user
  def provider_role(role) when role in [:assistant, "assistant"], do: :assistant
  def provider_role(role) when role in [:tool, "tool"], do: :tool

  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    ContentPart.text_content(content)
  end
end
