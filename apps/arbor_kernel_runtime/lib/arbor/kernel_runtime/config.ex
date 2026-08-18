defmodule Arbor.KernelRuntime.Config do
  @moduledoc """
  Owner-scoped application env for KernelRuntime.

  Values live under `config :arbor_kernel, kernel_runtime: [...]`. The
  closed start profile defaults to `:full`.
  """

  @doc """
  Closed start profile (`:full` or `:activation_only`).

  Missing defaults to `:full`. Unknown or malformed values are returned
  as configured so `Application.start` can fail closed.
  """
  @spec start_profile() :: term()
  def start_profile, do: get(:start_profile, :full)

  @namespace :kernel_runtime

  defp get(key, default) when is_atom(key) do
    case Application.fetch_env(:arbor_kernel, @namespace) do
      :error -> default
      {:ok, config} -> fetch_namespace_key(config, key, default)
    end
  end

  defp fetch_namespace_key(config, key, default) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.get(config, key, default)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp fetch_namespace_key(%{__struct__: _}, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp fetch_namespace_key(%{} = config, key, default) do
    Map.get(config, key, default)
  end

  defp fetch_namespace_key(_config, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp malformed_namespace_message do
    "Arbor.KernelRuntime.Config malformed :arbor_kernel :kernel_runtime namespace"
  end
end
