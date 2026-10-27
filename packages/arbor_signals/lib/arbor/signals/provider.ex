defmodule Arbor.Signals.Provider do
  @moduledoc false

  @type resolve_error :: :absent | :invalid_provider | :missing_callback
  @type invoke_error ::
          {:error, :provider_raised, module()}
          | {:error, :provider_threw}
          | {:error, :provider_exited}

  @spec resolve(term(), atom(), arity()) :: {:ok, module()} | {:error, resolve_error()}
  def resolve(nil, _function, _arity), do: {:error, :absent}
  def resolve(true, _function, _arity), do: {:error, :invalid_provider}
  def resolve(false, _function, _arity), do: {:error, :invalid_provider}

  def resolve(provider, _function, _arity) when not is_atom(provider),
    do: {:error, :invalid_provider}

  def resolve(provider, function, arity)
      when is_atom(provider) and is_atom(function) and is_integer(arity) and arity >= 0 do
    case Code.ensure_loaded(provider) do
      {:module, _} ->
        if function_exported?(provider, function, arity) do
          {:ok, provider}
        else
          {:error, :missing_callback}
        end

      _ ->
        {:error, :missing_callback}
    end
  end

  def resolve(_provider, _function, _arity), do: {:error, :invalid_provider}

  @spec invoke(module(), atom(), list()) :: {:ok, term()} | invoke_error()
  def invoke(provider, function, args) do
    {:ok, apply(provider, function, args)}
  rescue
    exception -> {:error, :provider_raised, exception.__struct__}
  catch
    :throw, _ -> {:error, :provider_threw}
    :exit, _ -> {:error, :provider_exited}
  end
end
