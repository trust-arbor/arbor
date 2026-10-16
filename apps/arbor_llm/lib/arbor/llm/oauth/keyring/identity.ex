defmodule Arbor.LLM.OAuth.Keyring.Identity do
  @moduledoc false

  @service "arbor.oauth"

  @spec service() :: String.t()
  def service, do: @service

  @spec credential_account(atom()) :: String.t()
  def credential_account(provider) when provider in [:openai, :xai],
    do: "provider:" <> Atom.to_string(provider)

  @spec file_key_account(atom()) :: String.t()
  def file_key_account(provider) when provider in [:openai, :xai],
    do: "file-key:" <> Atom.to_string(provider)
end
