defmodule Arbor.LLM.OAuth.Keyring.SecretTool do
  @moduledoc false

  @behaviour Arbor.LLM.OAuth.Keyring

  alias Arbor.LLM.OAuth.Keyring.StdinCmd

  @impl true
  def get(service, account) do
    case StdinCmd.run("secret-tool", lookup_args(service, account), nil) do
      {:ok, stdout} -> {:ok, trim_tool_newline(stdout)}
      {:error, {:keyring_command_failed, _status}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(service, account, secret) do
    case StdinCmd.run(
           "secret-tool",
           [
             "store",
             "--label",
             "Arbor OAuth " <> account,
             "service",
             service,
             "account",
             account
           ],
           secret
         ) do
      {:ok, _stdout} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(service, account) do
    case StdinCmd.run("secret-tool", ["clear", "service", service, "account", account], nil) do
      {:ok, _stdout} -> :ok
      {:error, {:keyring_command_failed, _status}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_args(service, account),
    do: ["lookup", "service", service, "account", account]

  defp trim_tool_newline(stdout) when is_binary(stdout),
    do: String.replace_suffix(stdout, "\n", "")
end
