defmodule Arbor.Memory.PrivateConversationSource do
  @moduledoc false

  alias Arbor.Contracts.Persistence.VectorRecord

  @scope_keys [:agent_id, :human_id, :engagement_id, :session_id, :turn_id]
  @source_keys ~w(descriptor stamp user_content assistant_content)
  @stamp_keys ~w(version issuer_id signature descriptor_digest)
  # The rendered content adds 18 bytes and must fit the canonical row string.
  @max_content_bytes 65_518

  def build(scope, pair) do
    with :ok <- validate_pair(pair),
         {:ok, descriptor} <- descriptor(scope, pair.user, pair.assistant) do
      {:ok,
       %{
         "descriptor" => descriptor,
         "user_content" => pair.user,
         "assistant_content" => pair.assistant
       }}
    else
      _ -> {:error, :invalid_private_memory_source}
    end
  end

  def validate_pair(pair) do
    if exact_keys?(pair, [:user, :assistant]),
      do: validate_texts(pair.user, pair.assistant),
      else: {:error, :invalid_private_memory_source}
  end

  # Validate the complete bounded source before admission, storage, or signing.
  # The descriptor must equal the body reconstructed from these actual texts.
  def admit(source) do
    with true <- exact_keys?(source, @source_keys),
         :ok <- validate_texts(source["user_content"], source["assistant_content"]),
         true <- valid_stamp?(source["stamp"]),
         descriptor when is_map(descriptor) <- source["descriptor"],
         {:ok, scope} <- source_scope(descriptor),
         {:ok, expected} <- descriptor(scope, source["user_content"], source["assistant_content"]),
         true <- descriptor === expected do
      {:ok, scope, render(source["user_content"], source["assistant_content"])}
    else
      _ -> {:error, :invalid_private_memory_source}
    end
  end

  def body(scope, source_id, content) do
    %{
      "content" => content,
      "metadata" => %{"type" => "conversation"},
      "source_id" => source_id,
      "conversation_scope" => string_scope(scope)
    }
  end

  def namespace(scope) do
    with {:ok, digest} <- VectorRecord.payload_digest([scope.agent_id, scope.human_id]),
         do: {:ok, "private_conversation_" <> digest}
  end

  def entry_id(scope, source_id) do
    with {:ok, digest} <- VectorRecord.payload_digest([scope.agent_id, scope.human_id, source_id]),
         do: {:ok, "private_mem_" <> digest}
  end

  defp descriptor(scope, user, assistant) do
    source_id = "session_turn:" <> scope.turn_id

    with true <- valid_label?(source_id),
         {:ok, namespace} <- namespace(scope),
         {:ok, id} <- entry_id(scope, source_id),
         {:ok, digest} <-
           VectorRecord.payload_digest(body(scope, source_id, render(user, assistant))) do
      {:ok,
       Map.merge(string_scope(scope), %{
         "source_id" => source_id,
         "id" => id,
         "source_namespace" => namespace,
         "source_key" => id,
         "body_digest" => digest,
         "user_role" => "user",
         "user_content_digest" => text_digest(user),
         "assistant_role" => "assistant",
         "assistant_content_digest" => text_digest(assistant)
       })}
    else
      _ -> {:error, :invalid_private_memory_source}
    end
  end

  defp source_scope(descriptor) do
    if Enum.all?(@scope_keys, &valid_label?(descriptor[Atom.to_string(&1)])) do
      {:ok, Map.new(@scope_keys, &{&1, descriptor[Atom.to_string(&1)]})}
    else
      {:error, :invalid_private_memory_source}
    end
  end

  defp validate_texts(user, assistant) do
    if is_binary(user) and is_binary(assistant) and user != "" and assistant != "" and
         byte_size(user) + byte_size(assistant) <= @max_content_bytes and
         String.valid?(user) and String.valid?(assistant),
       do: :ok,
       else: {:error, :invalid_private_memory_source}
  end

  defp valid_stamp?(stamp) do
    exact_keys?(stamp, @stamp_keys) and stamp["version"] === 1 and
      valid_label?(stamp["issuer_id"]) and is_binary(stamp["signature"]) and
      byte_size(stamp["signature"]) == 88 and is_binary(stamp["descriptor_digest"]) and
      byte_size(stamp["descriptor_digest"]) == 64
  end

  defp render(user, assistant), do: "User: " <> user <> "\nAssistant: " <> assistant
  defp text_digest(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
  defp string_scope(scope), do: Map.new(@scope_keys, &{Atom.to_string(&1), Map.fetch!(scope, &1)})

  defp valid_label?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp exact_keys?(map, keys) when is_map(map) and not is_struct(map),
    do: map_size(map) == length(keys) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_, _), do: false
end
