defmodule Arbor.AI.AcpSession.RuntimeHome do
  @moduledoc false

  @create_attempts 4

  @spec create() :: {:ok, map()} | {:error, :acp_runtime_home_unavailable}
  def create, do: create(@create_attempts)

  @spec inject(keyword(), map()) :: {:ok, keyword()} | {:error, atom()}
  def inject(client_opts, %{path: runtime_home})
      when is_list(client_opts) and is_binary(runtime_home) and runtime_home != "" do
    if Keyword.keyword?(client_opts) do
      if Keyword.has_key?(client_opts, :adapter) do
        inject_adapter(client_opts, runtime_home)
      else
        inject_native(client_opts, runtime_home)
      end
    else
      {:error, :invalid_acp_client_options}
    end
  end

  def inject(_client_opts, _cleanup_identity), do: {:error, :invalid_acp_client_options}

  @spec cleanup(map()) :: :ok | {:error, term()}
  def cleanup(cleanup_identity) when is_map(cleanup_identity) do
    Arbor.Shell.remove_owned_tree(cleanup_identity)
  end

  def cleanup(_cleanup_identity), do: {:error, :invalid_acp_runtime_home}

  defp create(0), do: {:error, :acp_runtime_home_unavailable}

  defp create(attempts_left) do
    case System.tmp_dir() do
      root when is_binary(root) and root != "" ->
        path =
          Path.join(
            Path.expand(root),
            "arbor-acp-runtime-" <>
              Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
          )

        case Arbor.Shell.create_private_owned_tree(path) do
          {:ok, cleanup_identity} -> {:ok, cleanup_identity}
          {:error, :root_exists} -> create(attempts_left - 1)
          {:error, _reason} -> {:error, :acp_runtime_home_unavailable}
        end

      _other ->
        {:error, :acp_runtime_home_unavailable}
    end
  end

  defp inject_native(client_opts, runtime_home) do
    with {:ok, env} <- put_arbor_home(Keyword.get(client_opts, :env), runtime_home) do
      {:ok, Keyword.put(client_opts, :env, env)}
    end
  end

  defp inject_adapter(client_opts, runtime_home) do
    case Keyword.get(client_opts, :adapter_opts, []) do
      adapter_opts when is_list(adapter_opts) ->
        if Keyword.keyword?(adapter_opts) do
          with {:ok, env} <- put_arbor_home(Keyword.get(adapter_opts, :env), runtime_home) do
            adapter_opts = Keyword.put(adapter_opts, :env, env)
            {:ok, Keyword.put(client_opts, :adapter_opts, adapter_opts)}
          end
        else
          {:error, :invalid_acp_adapter_options}
        end

      _other ->
        {:error, :invalid_acp_adapter_options}
    end
  end

  defp put_arbor_home(nil, runtime_home), do: {:ok, [{"ARBOR_HOME", runtime_home}]}

  defp put_arbor_home(env, runtime_home) when is_map(env) do
    env = env |> Map.drop(["ARBOR_HOME", :ARBOR_HOME, ~c"ARBOR_HOME"]) |> Map.to_list()
    {:ok, env ++ [{"ARBOR_HOME", runtime_home}]}
  end

  defp put_arbor_home(env, runtime_home) when is_list(env) do
    if Enum.all?(env, &(is_tuple(&1) and tuple_size(&1) == 2)) do
      env = Enum.reject(env, fn {key, _value} -> arbor_home_key?(key) end)
      {:ok, env ++ [{"ARBOR_HOME", runtime_home}]}
    else
      {:error, :invalid_acp_launch_env}
    end
  end

  defp put_arbor_home(_env, _runtime_home), do: {:error, :invalid_acp_launch_env}

  defp arbor_home_key?(key),
    do: key == "ARBOR_HOME" or key == :ARBOR_HOME or key == ~c"ARBOR_HOME"
end
