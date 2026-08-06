defmodule Arbor.Memory.MemoryStoreIdentity do
  @moduledoc false

  # Deterministic VectorRecord.id for MemoryStore semantic rows.
  # Logical identity remains {agent_id, namespace, key}; source_key is never the digest.

  @doc """
  Build a bounded deterministic row id for one MemoryStore semantic embedding.

  Encoding is length-prefixed UTF-8 segments so components cannot collide across
  delimiter boundaries: `<<len::32, agent_id, len::32, namespace, len::32, key>>`.
  """
  @spec row_id(String.t(), String.t(), String.t()) :: String.t()
  def row_id(agent_id, namespace, key)
      when is_binary(agent_id) and is_binary(namespace) and is_binary(key) do
    canonical =
      <<byte_size(agent_id)::32, agent_id::binary, byte_size(namespace)::32, namespace::binary,
        byte_size(key)::32, key::binary>>

    "ms_" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end
end
