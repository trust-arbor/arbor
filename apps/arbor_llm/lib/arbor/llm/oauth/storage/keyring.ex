defmodule Arbor.LLM.OAuth.Storage.Keyring do
  @moduledoc false

  @behaviour Arbor.LLM.OAuth.Storage

  alias Arbor.LLM.OAuth.Keyring
  alias Arbor.LLM.OAuth.Keyring.Identity
  alias Arbor.LLM.OAuth.Storage.File, as: FileBackend

  require Logger

  @impl true
  def fetch(key) when key in [:openai, :xai] do
    with {:ok, adapter} <- Keyring.adapter() do
      case adapter.get(Identity.service(), Identity.credential_account(key)) do
        {:ok, json} when is_binary(json) ->
          with :ok <- FileBackend.delete_plaintext(key), do: {:ok, json}

        {:error, :not_found} ->
          migrate_from_plaintext(adapter, key)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def store(key, json) when key in [:openai, :xai] and is_binary(json) do
    with {:ok, adapter} <- Keyring.adapter(),
         :ok <- adapter.put(Identity.service(), Identity.credential_account(key), json),
         :ok <- FileBackend.delete_plaintext(key) do
      :ok
    end
  end

  defp migrate_from_plaintext(adapter, key) do
    case FileBackend.fetch(key) do
      {:ok, json} ->
        with :ok <- adapter.put(Identity.service(), Identity.credential_account(key), json),
             :ok <- FileBackend.delete_plaintext(key) do
          Logger.info("oauth plaintext credential migrated to keyring provider=#{key}")
          {:ok, json}
        end

      {:error, {:token_file_unreadable, :enoent}} ->
        {:error, :not_found}

      other ->
        other
    end
  end
end
