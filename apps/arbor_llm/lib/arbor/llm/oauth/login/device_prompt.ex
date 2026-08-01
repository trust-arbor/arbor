defmodule Arbor.LLM.OAuth.Login.DevicePrompt do
  @moduledoc """
  Redacted result of `Arbor.LLM.OAuth.Login.start_xai_device_login/0`.

  RFC 8628 designs `:user_code`/`:verification_uri`/`:verification_uri_complete`
  to be shown to the human completing the flow, but none of them should leak
  through incidental `inspect/1` or logging -- use the explicit accessors
  below (intended for a future CLI/UI) instead of the raw struct fields.
  """

  @enforce_keys [:user_code, :verification_uri, :verification_uri_complete, :handle]
  defstruct [:user_code, :verification_uri, :verification_uri_complete, :handle]

  @type t :: %__MODULE__{
          user_code: String.t(),
          verification_uri: String.t(),
          verification_uri_complete: String.t() | nil,
          handle: String.t()
        }

  @doc "The short code the human types at the verification URI."
  @spec user_code(t()) :: String.t()
  def user_code(%__MODULE__{user_code: code}), do: code

  @doc "The URI the human visits to enter the user code."
  @spec verification_uri(t()) :: String.t()
  def verification_uri(%__MODULE__{verification_uri: uri}), do: uri

  @doc "The verification URI with the user code pre-filled, if the provider returned one."
  @spec verification_uri_complete(t()) :: String.t() | nil
  def verification_uri_complete(%__MODULE__{verification_uri_complete: uri}), do: uri

  defimpl Inspect do
    def inspect(_prompt, _opts) do
      "#Arbor.LLM.OAuth.Login.DevicePrompt<redacted>"
    end
  end
end
