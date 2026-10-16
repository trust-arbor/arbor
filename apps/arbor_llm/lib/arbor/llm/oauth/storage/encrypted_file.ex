defmodule Arbor.LLM.OAuth.Storage.EncryptedFile do
  @moduledoc false

  @behaviour Arbor.LLM.OAuth.Storage

  alias Arbor.LLM.OAuth.Keyring
  alias Arbor.LLM.OAuth.Keyring.Identity
  alias Arbor.LLM.OAuth.Storage
  alias Arbor.LLM.OAuth.Storage.AesGcm
  alias Arbor.LLM.OAuth.Storage.File, as: FileBackend
  alias Arbor.LLM.ResponseBudget

  require Logger

  @dek_bytes 32
  @envelope_limits [
    max_bytes: 1_048_576,
    max_nodes: 32,
    max_depth: 4,
    max_map_keys: 16,
    max_list_items: 8
  ]

  @impl true
  def fetch(key) when key in [:openai, :xai] do
    case read_encrypted(key) do
      {:ok, json} ->
        with :ok <- FileBackend.delete_plaintext(key), do: {:ok, json}

      {:error, :not_found} ->
        migrate_from_plaintext(key)

      other ->
        other
    end
  end

  @impl true
  def store(key, json) when key in [:openai, :xai] and is_binary(json) do
    write_encrypted(key, json)
  end

  defp migrate_from_plaintext(key) do
    case FileBackend.fetch(key) do
      {:ok, json} ->
        with :ok <- write_encrypted(key, json) do
          Logger.info("oauth plaintext credential migrated to encrypted file provider=#{key}")
          {:ok, json}
        end

      {:error, {:token_file_unreadable, :enoent}} ->
        {:error, :not_found}

      other ->
        other
    end
  end

  defp read_encrypted(key) do
    path = Storage.encrypted_path(key)

    case File.read(path) do
      {:ok, body} ->
        with {:ok, envelope} <- decode_envelope(body),
             {:ok, dek} <- load_file_key(key),
             {:ok, json} <- AesGcm.unwrap(envelope, dek, Atom.to_string(key)) do
          {:ok, json}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:token_file_unreadable, reason}}
    end
  end

  defp write_encrypted(key, json) do
    with {:ok, dek} <- ensure_file_key(key),
         {:ok, envelope} <-
           AesGcm.wrap(json, dek, :crypto.strong_rand_bytes(12), Atom.to_string(key)),
         {:ok, body} <- encode_envelope(envelope),
         :ok <- FileBackend.atomic_write(key, Storage.encrypted_path(key), body),
         :ok <- FileBackend.delete_plaintext(key) do
      :ok
    end
  end

  defp ensure_file_key(key) do
    with {:ok, adapter} <- Keyring.adapter() do
      account = Identity.file_key_account(key)

      case adapter.get(Identity.service(), account) do
        {:ok, encoded} ->
          decode_dek(encoded)

        {:error, :not_found} ->
          dek = :crypto.strong_rand_bytes(@dek_bytes)

          case adapter.put(Identity.service(), account, Base.encode64(dek)) do
            :ok -> {:ok, dek}
            error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp load_file_key(key) do
    with {:ok, adapter} <- Keyring.adapter() do
      case adapter.get(Identity.service(), Identity.file_key_account(key)) do
        {:ok, encoded} -> decode_dek(encoded)
        {:error, :not_found} -> {:error, :oauth_file_key_missing}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_dek(encoded) when is_binary(encoded) do
    case Base.decode64(String.replace_suffix(encoded, "\n", "")) do
      {:ok, dek} when byte_size(dek) == @dek_bytes -> {:ok, dek}
      _ -> {:error, :invalid_oauth_file_key}
    end
  end

  defp decode_envelope(body) when is_binary(body) do
    case ResponseBudget.decode_json(body, @envelope_limits) do
      {:ok, %{} = envelope} -> {:ok, envelope}
      {:ok, _other} -> {:error, :invalid_encrypted_envelope}
      {:error, reason} -> {:error, {:token_file_unreadable, reason}}
    end
  end

  defp encode_envelope(envelope) when is_map(envelope) do
    case Jason.encode(envelope) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:token_store_write_failed, {:encode_failed, reason}}}
    end
  end
end
