defmodule Arbor.LLM.OAuth.Keyring do
  @moduledoc """
  OS-keyring adapter for Arbor-owned OAuth credential bytes.

  Production uses `Arbor.LLM.OAuth.Keyring.OS` (`security` on macOS,
  `secret-tool` on Linux). Tests inject `Arbor.LLM.OAuth.Keyring.Memory`.
  Secrets are never included in adapter errors or command argv.
  """

  @type service :: String.t()
  @type account :: String.t()
  @type secret :: String.t()

  @callback get(service(), account()) ::
              {:ok, secret()} | {:error, :not_found | term()}

  @callback put(service(), account(), secret()) :: :ok | {:error, term()}

  @callback delete(service(), account()) :: :ok | {:error, term()}

  @doc false
  @spec adapter() :: {:ok, module()} | {:error, :keyring_adapter_invalid}
  def adapter do
    case Application.get_env(:arbor_llm, :oauth_keyring_adapter, Arbor.LLM.OAuth.Keyring.OS) do
      module when is_atom(module) ->
        case Code.ensure_loaded(module) do
          {:module, ^module} ->
            if function_exported?(module, :get, 2) and function_exported?(module, :put, 3) and
                 function_exported?(module, :delete, 2) do
              {:ok, module}
            else
              {:error, :keyring_adapter_invalid}
            end

          _ ->
            {:error, :keyring_adapter_invalid}
        end

      _other ->
        {:error, :keyring_adapter_invalid}
    end
  end
end
