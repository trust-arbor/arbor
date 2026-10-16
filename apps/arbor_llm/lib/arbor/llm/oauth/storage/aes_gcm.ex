defmodule Arbor.LLM.OAuth.Storage.AesGcm do
  @moduledoc false

  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32
  @fields ["v", "alg", "provider", "iv", "tag", "ct"]
  @aad_prefix "arbor-oauth-encrypted-file-v1:"

  @spec wrap(binary(), binary(), binary(), String.t()) ::
          {:ok, map()} | {:error, :invalid_encrypted_envelope}
  def wrap(plaintext, key, iv, provider)
      when is_binary(plaintext) and is_binary(key) and byte_size(key) == @key_bytes and
             is_binary(iv) and byte_size(iv) == @iv_bytes and is_binary(provider) and
             provider in ["openai", "xai"] do
    aad = aad(provider)

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, @tag_bytes, true)

    {:ok,
     %{
       "v" => 1,
       "alg" => "aes-256-gcm",
       "provider" => provider,
       "iv" => Base.encode64(iv),
       "tag" => Base.encode64(tag),
       "ct" => Base.encode64(ct)
     }}
  end

  def wrap(_plaintext, _key, _iv, _provider), do: {:error, :invalid_encrypted_envelope}

  @spec unwrap(map(), binary(), String.t()) ::
          {:ok, binary()}
          | {:error, :encrypted_oauth_decrypt_failed | :invalid_encrypted_envelope}
  def unwrap(%{} = envelope, key, provider)
      when is_binary(key) and is_binary(provider) and provider in ["openai", "xai"] do
    with :ok <- exact_fields(envelope),
         1 <- envelope["v"],
         "aes-256-gcm" <- envelope["alg"],
         ^provider <- envelope["provider"],
         true <- byte_size(key) == @key_bytes,
         {:ok, iv} <- decode64(envelope["iv"], @iv_bytes),
         {:ok, tag} <- decode64(envelope["tag"], @tag_bytes),
         {:ok, ct} <- decode64(envelope["ct"], :any) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ct,
             aad(provider),
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :encrypted_oauth_decrypt_failed}
      end
    else
      _other -> {:error, :invalid_encrypted_envelope}
    end
  end

  def unwrap(_envelope, _key, _provider), do: {:error, :invalid_encrypted_envelope}

  defp aad(provider), do: @aad_prefix <> provider

  defp exact_fields(envelope) do
    if map_size(envelope) == length(@fields) and
         Enum.sort(Map.keys(envelope)) == Enum.sort(@fields) do
      :ok
    else
      {:error, :invalid_fields}
    end
  end

  defp decode64(value, expected_bytes)
       when is_binary(value) and is_integer(expected_bytes) do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) == expected_bytes -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode64(value, :any) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode64(_value, _expected), do: :error
end
