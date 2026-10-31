defmodule Arbor.Trust.ProfileStore do
  @moduledoc "Explicit profile persistence composition. Durable writes remain acknowledged directly by Store; memory mode makes no durable claim."
  @keys [:mode, :backend, :backend_opts, :collection, :buffered_name]
  @callbacks [get: 2, put: 3, delete: 2, list: 1]

  def child_specs do
    case Application.get_env(:arbor_trust, :profile_store) do
      [mode: :memory] -> {:ok, [{Arbor.Trust.Store, [persistence: :memory]}]}
      nil -> {:error, :trust_profile_store_unconfigured}
      opts when is_list(opts) -> durable_specs(opts)
      _ -> {:error, :invalid_trust_profile_store}
    end
  end

  defp durable_specs(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == Enum.sort(@keys) and
         opts[:mode] == :durable and is_atom(opts[:backend]) and
         opts[:backend] not in [nil, true, false] and
         is_list(opts[:backend_opts]) and Keyword.keyword?(opts[:backend_opts]) and
         is_binary(opts[:collection]) and byte_size(opts[:collection]) > 0 and
         is_atom(opts[:buffered_name]) and opts[:buffered_name] not in [nil, true, false] do
      backend = opts[:backend]

      if Code.ensure_loaded?(backend) and
           Enum.all?(@callbacks, fn {name, arity} -> function_exported?(backend, name, arity) end) do
        {:ok,
         [
           Supervisor.child_spec(
             {Arbor.Persistence.BufferedStore,
              name: opts[:buffered_name],
              backend: backend,
              backend_opts: opts[:backend_opts],
              write_mode: :sync,
              collection: opts[:collection]},
             id: opts[:buffered_name]
           ),
           {Arbor.Trust.Store,
            [
              persistence: :durable,
              durable_backend: backend,
              durable_backend_opts: opts[:backend_opts],
              durable_collection: opts[:collection]
            ]}
         ]}
      else
        {:error, :trust_profile_store_unavailable}
      end
    else
      {:error, :invalid_trust_profile_store}
    end
  rescue
    _ -> {:error, :invalid_trust_profile_store}
  catch
    _, _ -> {:error, :trust_profile_store_unavailable}
  end
end
