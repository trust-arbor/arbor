defmodule Arbor.Actions.Coding.GitBlobOid do
  @moduledoc false

  @type format :: :sha1 | :sha256
  @type digest_state :: {format(), term()}

  @doc false
  @spec blob_header(non_neg_integer()) :: iodata()
  def blob_header(size) when is_integer(size) and size >= 0 do
    ["blob ", Integer.to_string(size), <<0>>]
  end

  @doc false
  @spec hash_init(term(), term()) ::
          {:ok, digest_state()} | {:error, :committable_snapshot_failed}
  def hash_init(format, size)
      when format in [:sha1, :sha256] and is_integer(size) and size >= 0 do
    state = :crypto.hash_init(crypto_algo(format))
    {:ok, {format, :crypto.hash_update(state, blob_header(size))}}
  end

  def hash_init(_format, _size), do: {:error, :committable_snapshot_failed}

  @doc false
  @spec hash_update(term(), term()) ::
          {:ok, digest_state()} | {:error, :committable_snapshot_failed}
  def hash_update({format, state}, chunk)
      when format in [:sha1, :sha256] and is_binary(chunk) do
    {:ok, {format, :crypto.hash_update(state, chunk)}}
  end

  def hash_update(_state, _chunk), do: {:error, :committable_snapshot_failed}

  @doc false
  @spec hash_final(term()) :: {:ok, String.t()} | {:error, :committable_snapshot_failed}
  def hash_final({format, state}) when format in [:sha1, :sha256] do
    oid = state |> :crypto.hash_final() |> Base.encode16(case: :lower)
    expected = oid_width(format)

    if byte_size(oid) == expected do
      {:ok, oid}
    else
      {:error, :committable_snapshot_failed}
    end
  end

  def hash_final(_state), do: {:error, :committable_snapshot_failed}

  @doc false
  @spec hash_bytes(term(), term()) ::
          {:ok, String.t()} | {:error, :committable_snapshot_failed}
  def hash_bytes(bytes, format) when is_binary(bytes) do
    with {:ok, state} <- hash_init(format, byte_size(bytes)),
         {:ok, state} <- hash_update(state, bytes) do
      hash_final(state)
    end
  end

  def hash_bytes(_bytes, _format), do: {:error, :committable_snapshot_failed}

  defp crypto_algo(:sha1), do: :sha
  defp crypto_algo(:sha256), do: :sha256

  defp oid_width(:sha1), do: 40
  defp oid_width(:sha256), do: 64
end
