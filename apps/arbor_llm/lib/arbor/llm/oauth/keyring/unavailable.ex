defmodule Arbor.LLM.OAuth.Keyring.Unavailable do
  @moduledoc false

  @behaviour Arbor.LLM.OAuth.Keyring

  @impl true
  def get(_service, _account), do: {:error, :keyring_unsupported_platform}

  @impl true
  def put(_service, _account, _secret), do: {:error, :keyring_unsupported_platform}

  @impl true
  def delete(_service, _account), do: {:error, :keyring_unsupported_platform}
end
