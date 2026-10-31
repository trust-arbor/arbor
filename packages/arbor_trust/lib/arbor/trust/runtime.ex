defmodule Arbor.Trust.Runtime do
  @moduledoc """
  Fail-closed invocation of the statically configured runtime host.

  An absent or explicitly nil provider selects standalone ownership. A present
  invalid provider is authoritative and cannot reopen that standalone path.
  The package owns its real application tree in both modes.
  """

  @app :arbor_trust
  @callbacks [
    prepare_startup: 0,
    start_profile: 0,
    provider_gate_child_spec: 2,
    start_provider_gate_supervisor: 3
  ]

  @type runtime_error ::
          :runtime_host_unavailable
          | :invalid_runtime_host_response
          | :invalid_runtime_configuration
          | {:invalid_start_profile, term()}
          | term()

  @spec prepare_startup() :: :ok | {:error, runtime_error()}
  def prepare_startup do
    with {:ok, provider} <- provider(),
         :ok <- prepare_provider(provider),
         profile when profile in [:full, :activation_only] <- profile_for(provider) do
      :ok
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_start_profile, other}}
    end
  end

  @spec start_profile() :: :full | :activation_only | {:error, runtime_error()}
  def start_profile do
    with {:ok, provider} <- provider(), do: profile_for(provider)
  end

  @doc false
  @spec provider_gate_child_spec(atom(), [atom()]) ::
          :none | {:ok, Supervisor.child_spec()} | {:error, runtime_error()}
  def provider_gate_child_spec(name, roots) do
    with {:ok, provider} <- provider() do
      if is_nil(provider) do
        :none
      else
        case invoke(provider, :provider_gate_child_spec, [name, roots]) do
          %{id: ^name, start: {module, function, args}} = spec
          when is_atom(module) and is_atom(function) and is_list(args) ->
            {:ok, spec}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, :invalid_runtime_host_response}
        end
      end
    end
  end

  @doc false
  @spec start_provider_gate_supervisor([Supervisor.child_spec()], atom(), atom()) ::
          {:ok, pid()} | {:error, runtime_error()}
  def start_provider_gate_supervisor(children, supervisor_name, gate_name) do
    case provider() do
      {:ok, provider} when not is_nil(provider) ->
        case invoke(provider, :start_provider_gate_supervisor, [
               children,
               supervisor_name,
               gate_name
             ]) do
          {:ok, pid} = started when is_pid(pid) ->
            if node(pid) == node() and Process.alive?(pid),
              do: started,
              else: {:error, :invalid_runtime_host_response}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, :invalid_runtime_host_response}
        end

      {:ok, nil} ->
        {:error, :runtime_host_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp provider do
    case Application.get_env(@app, :runtime_host) do
      nil ->
        {:ok, nil}

      module when is_atom(module) and module not in [true, false] ->
        if Code.ensure_loaded?(module) and
             Enum.all?(@callbacks, fn {callback, arity} ->
               function_exported?(module, callback, arity)
             end) do
          {:ok, module}
        else
          {:error, :runtime_host_unavailable}
        end

      _invalid ->
        {:error, :runtime_host_unavailable}
    end
  rescue
    _ -> {:error, :runtime_host_unavailable}
  catch
    _, _ -> {:error, :runtime_host_unavailable}
  end

  defp prepare_provider(nil), do: :ok

  defp prepare_provider(provider) do
    case invoke(provider, :prepare_startup, []) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_runtime_host_response}
    end
  end

  defp profile_for(nil) do
    case Application.get_env(@app, :runtime, start_profile: :full) do
      config when is_list(config) ->
        if Keyword.keyword?(config) and Keyword.keys(config) == [:start_profile],
          do: admit_profile(Keyword.fetch!(config, :start_profile)),
          else: {:error, :invalid_runtime_configuration}

      _invalid ->
        {:error, :invalid_runtime_configuration}
    end
  end

  defp profile_for(provider) do
    case invoke(provider, :start_profile, []) do
      {:error, _reason} = error -> error
      profile -> admit_profile(profile)
    end
  end

  defp admit_profile(profile) when profile in [:full, :activation_only], do: profile
  defp admit_profile(other), do: {:error, {:invalid_start_profile, other}}

  defp invoke(provider, callback, args) do
    apply(provider, callback, args)
  rescue
    _ -> {:error, :runtime_host_unavailable}
  catch
    _, _ -> {:error, :runtime_host_unavailable}
  end
end
