defmodule Arbor.LLM.OAuth.Storage do
  @moduledoc """
  Optional OAuth credential storage backends.

  `:file` (default) writes a 0600 JSON envelope at `~/.arbor/oauth/<provider>.json`.
  `:keyring` stores the envelope in the OS keyring.
  `:encrypted_file` writes AES-GCM ciphertext and keeps the DEK in the keyring.

  Configure with `config :arbor_llm, oauth_storage_backend: :file | :keyring | :encrypted_file`
  or `ARBOR_OAUTH_STORAGE`. See `docs/arbor/OAUTH_CREDENTIAL_STORAGE.md`.
  """

  @callback fetch(atom()) :: {:ok, binary()} | {:error, term()}
  @callback store(atom(), binary()) :: :ok | {:error, term()}

  @default_store_dir "~/.arbor/oauth"

  @spec fetch(atom()) :: {:ok, binary()} | {:error, term()}
  def fetch(key) when key in [:openai, :xai] do
    case backend() do
      {:ok, module} -> module.fetch(key)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec store(atom(), binary()) :: :ok | {:error, term()}
  def store(key, json) when key in [:openai, :xai] and is_binary(json) do
    case backend() do
      {:ok, module} -> module.store(key, json)
      {:error, reason} -> {:error, reason}
    end
  end

  def store(_key, _json), do: {:error, {:token_store_write_failed, :invalid_tokens}}

  @spec store_dir() :: String.t()
  def store_dir do
    case Application.get_env(:arbor_llm, :oauth_store_dir) do
      dir when is_binary(dir) and byte_size(dir) > 0 ->
        Path.expand(dir)

      _ ->
        Path.expand(@default_store_dir)
    end
  end

  @spec plaintext_path(atom()) :: String.t()
  def plaintext_path(key) when key in [:openai, :xai],
    do: Path.join(store_dir(), "#{key}.json")

  @spec encrypted_path(atom()) :: String.t()
  def encrypted_path(key) when key in [:openai, :xai],
    do: Path.join(store_dir(), "#{key}.enc")

  defp backend do
    case Application.get_env(:arbor_llm, :oauth_storage_backend, :file) do
      :file -> {:ok, Arbor.LLM.OAuth.Storage.File}
      :keyring -> {:ok, Arbor.LLM.OAuth.Storage.Keyring}
      :encrypted_file -> {:ok, Arbor.LLM.OAuth.Storage.EncryptedFile}
      other -> {:error, {:unsupported_oauth_storage_backend, backend_name(other)}}
    end
  end

  defp backend_name(other) when is_atom(other), do: other
  defp backend_name(_other), do: :invalid
end
