defmodule Arbor.Security.OIDC.TokenCacheOwner do
  @moduledoc false

  use GenServer

  alias Arbor.Security.SupervisedOwner

  @name __MODULE__
  @directory :arbor_security_oidc_token_cache_owner_directory

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @retired_error {:error, :oidc_token_cache_unauthorized}

  # Persisted OIDC bearer and refresh tokens are intentionally retired. Keep
  # this module as the supervised owner boundary so stale callers and direct
  # protocol messages fail closed with one stable result.
  def load, do: @retired_error

  def store(token_response, claims) when is_map(token_response) and is_map(claims),
    do: @retired_error

  def store(_token_response, _claims), do: {:error, :invalid_token_cache_input}

  @doc false
  def owner_process?, do: match?({:ok, owner} when owner == self(), owner_pid())

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)

    with :ok <- claim_directory() do
      {:ok, nil}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:load, _from, state), do: {:reply, @retired_error, state}

  def handle_call({:store, token_response, claims}, _from, state),
    do: {:reply, retired_store_result(token_response, claims), state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :invalid_token_cache_request}, state}

  @impl true
  def format_status(status) when is_map(status), do: Map.put(status, :state, :redacted)

  defp retired_store_result(token_response, claims)
       when is_map(token_response) and is_map(claims),
       do: @retired_error

  defp retired_store_result(_token_response, _claims), do: {:error, :invalid_token_cache_input}

  defp claim_directory do
    table = :ets.new(@directory, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :token_cache_owner_directory_unavailable}
  end

  defp owner_pid do
    case SupervisedOwner.protected_directory_owner(
           @directory,
           :owner,
           :arbor_security,
           [__MODULE__]
         ) do
      owner when is_pid(owner) -> {:ok, owner}
      nil -> {:error, :token_cache_unavailable}
    end
  end
end
