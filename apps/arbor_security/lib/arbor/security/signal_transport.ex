defmodule Arbor.Security.SignalTransport do
  @moduledoc false

  alias Arbor.Security.Config

  @unavailable {:error, :security_sync_provider_unavailable}
  @invalid_response {:error, :invalid_security_sync_provider_response}
  @callbacks [
    security_sync_transport_configured?: 0,
    security_sync_role_configured?: 1,
    subscribe_security_sync: 2,
    unsubscribe: 1,
    admit_remote_security_mutation?: 1,
    emit: 4
  ]

  @spec capture() :: {:ok, module() | nil} | {:error, :security_sync_provider_unavailable}
  def capture do
    case Config.signal_transport() do
      nil -> {:ok, nil}
      provider -> if valid_provider?(provider), do: {:ok, provider}, else: @unavailable
    end
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  @spec configured?() :: boolean()
  def configured? do
    case capture() do
      {:ok, provider} -> configured_or_unavailable?(provider)
      {:error, _reason} -> true
    end
  end

  @spec configured?(module() | nil) ::
          {:ok, boolean()}
          | {:error,
             :security_sync_provider_unavailable | :invalid_security_sync_provider_response}
  def configured?(nil), do: {:ok, false}

  def configured?(provider),
    do: boolean_callback(provider, :security_sync_transport_configured?, [])

  @spec role_configured?(module(), atom()) ::
          {:ok, boolean()}
          | {:error,
             :security_sync_provider_unavailable | :invalid_security_sync_provider_response}
  def role_configured?(provider, role),
    do: boolean_callback(provider, :security_sync_role_configured?, [role])

  @spec subscribe(module(), atom(), atom()) ::
          {:ok, String.t(), pid(), reference()} | {:error, term()}
  def subscribe(provider, role, event) do
    case invoke(provider, :subscribe_security_sync, [role, event]) do
      {:ok, id, pid, reference} = result
      when is_binary(id) and byte_size(id) > 0 and is_pid(pid) and is_reference(reference) ->
        if node(pid) == node() and Process.alive?(pid) do
          result
        else
          _ = unsubscribe(provider, id)
          @invalid_response
        end

      {:error, _reason} = error ->
        error

      malformed ->
        cleanup_malformed_subscription(provider, malformed)
        @invalid_response
    end
  end

  @spec unsubscribe(module(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(provider, id), do: effect_callback(provider, :unsubscribe, [id])

  @spec admit_remote_security_mutation?(module(), atom()) :: boolean()
  def admit_remote_security_mutation?(provider, type),
    do: boolean_callback(provider, :admit_remote_security_mutation?, [type]) == {:ok, true}

  @spec emit(module(), atom(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def emit(provider, category, type, data, opts),
    do: effect_callback(provider, :emit, [category, type, data, opts])

  defp configured_or_unavailable?(provider) do
    case configured?(provider) do
      {:ok, configured} -> configured
      {:error, _reason} -> true
    end
  end

  defp valid_provider?(provider) do
    is_atom(provider) and provider not in [nil, true, false] and
      Code.ensure_loaded?(provider) and
      Enum.all?(@callbacks, fn {name, arity} -> function_exported?(provider, name, arity) end)
  end

  defp invoke(provider, callback, args) do
    if valid_provider?(provider), do: apply(provider, callback, args), else: @unavailable
  rescue
    _ -> @unavailable
  catch
    _, _ -> @unavailable
  end

  defp boolean_callback(provider, callback, args) do
    case invoke(provider, callback, args) do
      value when is_boolean(value) -> {:ok, value}
      @unavailable -> @unavailable
      _malformed -> @invalid_response
    end
  end

  defp effect_callback(provider, callback, args) do
    case invoke(provider, callback, args) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _malformed -> @invalid_response
    end
  end

  defp cleanup_malformed_subscription(provider, {:ok, id, _pid, _reference})
       when is_binary(id) and byte_size(id) > 0 do
    _ = unsubscribe(provider, id)
    :ok
  end

  defp cleanup_malformed_subscription(provider, {:ok, id, _pid})
       when is_binary(id) and byte_size(id) > 0 do
    _ = unsubscribe(provider, id)
    :ok
  end

  defp cleanup_malformed_subscription(_provider, _malformed), do: :ok
end
