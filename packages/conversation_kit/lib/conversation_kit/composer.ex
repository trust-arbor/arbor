defmodule ConversationKit.Composer do
  @moduledoc """
  Pure draft and submission decisions shared by native conversation surfaces.

  A submission pins a stable request ID and the local draft revision. Host
  acknowledgement releases only that submission. It clears the draft only if
  the user has made no subsequent edit, including editing back to identical
  text. Durable messages and delivery status remain outside this value.
  """

  def new, do: %{draft: "", revision: 0, submitted: nil}

  def draft(composer, text) when is_binary(text),
    do: %{composer | draft: text, revision: composer.revision + 1}

  def submit(composer, allowed, id) when is_boolean(allowed) and is_binary(id) do
    if allowed and is_nil(composer.submitted) and String.trim(composer.draft) != "" do
      request = %{id: id, text: composer.draft}
      {:send, request, %{composer | submitted: Map.put(request, :revision, composer.revision)}}
    else
      {:ignored, composer}
    end
  end

  def acknowledge(
        %{submitted: %{id: id, text: text, revision: revision}} = composer,
        %{id: id, text: text}
      ) do
    draft = if composer.revision == revision, do: "", else: composer.draft
    %{composer | submitted: nil, draft: draft}
  end

  def acknowledge(composer, _receipt), do: composer

  def reject(%{submitted: %{id: id}} = composer, id), do: %{composer | submitted: nil}
  def reject(composer, _id), do: composer

  @doc "Clear active private input and release its submission on access or ownership loss."
  def clear(composer),
    do: %{composer | draft: "", revision: composer.revision + 1, submitted: nil}
end
