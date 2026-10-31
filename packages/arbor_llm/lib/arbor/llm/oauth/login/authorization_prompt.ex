defmodule Arbor.LLM.OAuth.Login.AuthorizationPrompt do
  @moduledoc """
  Redacted result of `Arbor.LLM.OAuth.Login.start_openai_login/1`.

  `:authorize_url` embeds the CSRF `state` and PKCE `code_challenge` as
  query values and must never appear via incidental `inspect/1` or logging;
  `authorize_url/1` gives a deliberate caller (a future browser
  launcher/CLI) explicit access instead.
  """

  @enforce_keys [:authorize_url, :handle]
  defstruct [:authorize_url, :handle]

  @type t :: %__MODULE__{authorize_url: String.t(), handle: String.t()}

  @doc "The full authorization URL to open in a browser."
  @spec authorize_url(t()) :: String.t()
  def authorize_url(%__MODULE__{authorize_url: url}), do: url

  defimpl Inspect do
    def inspect(_prompt, _opts) do
      "#Arbor.LLM.OAuth.Login.AuthorizationPrompt<redacted>"
    end
  end
end
