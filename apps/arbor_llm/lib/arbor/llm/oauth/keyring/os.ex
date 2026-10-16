defmodule Arbor.LLM.OAuth.Keyring.OS do
  @moduledoc false

  @behaviour Arbor.LLM.OAuth.Keyring

  @impl true
  def get(service, account), do: backend().get(service, account)

  @impl true
  def put(service, account, secret), do: backend().put(service, account, secret)

  @impl true
  def delete(service, account), do: backend().delete(service, account)

  defp backend do
    case :os.type() do
      {:unix, :darwin} -> Arbor.LLM.OAuth.Keyring.Security
      {:unix, _other} -> Arbor.LLM.OAuth.Keyring.SecretTool
      _other -> Arbor.LLM.OAuth.Keyring.Unavailable
    end
  end
end
