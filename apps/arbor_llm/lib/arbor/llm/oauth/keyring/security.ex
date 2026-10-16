defmodule Arbor.LLM.OAuth.Keyring.Security do
  @moduledoc false

  @behaviour Arbor.LLM.OAuth.Keyring

  alias Arbor.LLM.OAuth.Keyring.StdinCmd

  @impl true
  def get(service, account) do
    case StdinCmd.run(
           "security",
           ["find-generic-password", "-s", service, "-a", account, "-w"],
           nil
         ) do
      {:ok, stdout} ->
        case Base.decode64(trim_tool_newline(stdout), padding: true) do
          {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 ->
            {:ok, secret}

          _ ->
            {:error, :invalid_keyring_secret}
        end

      {:error, {:keyring_command_failed, _status}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put(service, account, secret) do
    with :ok <- validate_identity(service, account) do
      payload = Base.encode64(secret, padding: true)

      script =
        "add-generic-password -U -s " <>
          service <> " -a " <> account <> " -w " <> payload <> "\n"

      case StdinCmd.run("security", ["-i"], script) do
        {:ok, _stdout} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_identity(service, account) do
    if safe_token?(service) and safe_token?(account) do
      :ok
    else
      {:error, :invalid_keyring_identity}
    end
  end

  defp safe_token?(value) when is_binary(value) do
    String.match?(value, ~r/\A[A-Za-z0-9._:-]+\z/)
  end

  defp safe_token?(_value), do: false

  @impl true
  def delete(service, account) do
    case StdinCmd.run(
           "security",
           ["delete-generic-password", "-s", service, "-a", account],
           nil
         ) do
      {:ok, _stdout} -> :ok
      {:error, {:keyring_command_failed, _status}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp trim_tool_newline(stdout) when is_binary(stdout),
    do: String.replace_suffix(stdout, "\n", "")
end
