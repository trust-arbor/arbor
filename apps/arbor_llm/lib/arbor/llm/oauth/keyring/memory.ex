defmodule Arbor.LLM.OAuth.Keyring.Memory do
  @moduledoc """
  In-process keyring adapter for tests. Do not use in production.

  Holds secrets in an Agent; nothing is written to disk. Named so a hermetic
  OAuth suite can start/stop it without a real OS keyring.
  """

  @behaviour Arbor.LLM.OAuth.Keyring

  @max_service_bytes 256
  @max_account_bytes 256
  @max_secret_bytes 1_048_576

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @impl true
  def get(service, account) do
    with :ok <- validate_identity(service, account) do
      call(fn table ->
        case Map.fetch(table, {service, account}) do
          {:ok, secret} -> {:ok, secret}
          :error -> {:error, :not_found}
        end
      end)
    end
  end

  @impl true
  def put(service, account, secret) do
    with :ok <- validate_identity(service, account),
         :ok <- validate_secret(secret) do
      call(fn table ->
        {:ok, Map.put(table, {service, account}, secret)}
      end)
    end
  end

  @impl true
  def delete(service, account) do
    with :ok <- validate_identity(service, account) do
      call(fn table ->
        {:ok, Map.delete(table, {service, account})}
      end)
    end
  end

  @doc false
  def reset do
    call(fn _table -> {:ok, %{}} end)
  end

  defp call(fun) when is_function(fun, 1) do
    Agent.get_and_update(__MODULE__, fn table ->
      case fun.(table) do
        {:ok, secret} when is_binary(secret) -> {{:ok, secret}, table}
        {:error, reason} -> {{:error, reason}, table}
        {:ok, new_table} when is_map(new_table) -> {:ok, new_table}
      end
    end)
  catch
    :exit, {:noproc, _} -> {:error, :keyring_unavailable}
    :exit, {:timeout, _} -> {:error, :keyring_unavailable}
  end

  defp validate_identity(service, account)
       when is_binary(service) and is_binary(account) and
              byte_size(service) > 0 and byte_size(service) <= @max_service_bytes and
              byte_size(account) > 0 and byte_size(account) <= @max_account_bytes do
    if String.valid?(service) and String.valid?(account) do
      :ok
    else
      {:error, :invalid_keyring_identity}
    end
  end

  defp validate_identity(_service, _account), do: {:error, :invalid_keyring_identity}

  defp validate_secret(secret)
       when is_binary(secret) and byte_size(secret) > 0 and byte_size(secret) <= @max_secret_bytes do
    :ok
  end

  defp validate_secret(_secret), do: {:error, :invalid_keyring_secret}
end
