defmodule Arbor.Orchestrator.CrossAppContinuation.Store do
  @moduledoc false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence

  @type config :: %{
          backend: module(),
          store_name: atom(),
          backend_opts: keyword(),
          max_items: pos_integer(),
          max_data_bytes: pos_integer()
        }

  @spec attest(config()) ::
          {:ok, :node_restart} | {:error, :unsupported | :insufficient_durability | :unavailable}
  def attest(config) when is_map(config) do
    cond do
      not Persistence.supports_compare_and_swap?(config.backend) ->
        {:error, :unsupported}

      not Persistence.supports_durability_class?(config.backend) ->
        {:error, :unsupported}

      true ->
        case safe(fn ->
               Persistence.durability_class(
                 config.store_name,
                 config.backend,
                 config.backend_opts
               )
             end) do
          {:ok, {:ok, :node_restart}} -> {:ok, :node_restart}
          {:ok, {:ok, _other}} -> {:error, :insufficient_durability}
          {:ok, {:error, :unsupported}} -> {:error, :unsupported}
          {:ok, {:error, _reason}} -> {:error, :unavailable}
          {:ok, _other} -> {:error, :unavailable}
          {:error, _reason} -> {:error, :unavailable}
        end
    end
  end

  @spec get(config(), String.t()) :: {:ok, Record.t()} | {:error, atom()}
  def get(config, key) when is_binary(key) do
    case safe(fn ->
           Persistence.get(config.store_name, config.backend, key, config.backend_opts)
         end) do
      {:ok, {:error, :not_found}} -> {:error, :not_found}
      {:ok, {:ok, %Record{key: ^key} = record}} -> {:ok, record}
      {:ok, {:ok, %Record{}}} -> {:error, :malformed_record}
      {:ok, {:error, _reason}} -> {:error, :unavailable}
      {:error, _reason} -> {:error, :unavailable}
      _other -> {:error, :malformed_record}
    end
  end

  @spec list(config()) :: {:ok, [String.t()]} | {:error, atom()}
  def list(config) do
    opts = Keyword.put(config.backend_opts, :authoritative_limit, config.max_items + 1)

    case safe(fn -> Persistence.list(config.store_name, config.backend, opts) end) do
      {:ok, {:ok, keys}} when is_list(keys) -> {:ok, keys}
      {:ok, {:error, _reason}} -> {:error, :unavailable}
      {:error, _reason} -> {:error, :unavailable}
      _other -> {:error, :malformed_record}
    end
  end

  @spec insert_absent(config(), Record.t()) :: {:ok, Record.t()} | {:error, atom()}
  def insert_absent(config, %Record{} = record) do
    cas(config, record.key, :not_found, record)
  end

  @spec cas(config(), String.t(), :not_found | {:value, Record.t()}, Record.t()) ::
          {:ok, Record.t()} | {:error, atom()}
  def cas(config, key, expected, %Record{} = replacement) when is_binary(key) do
    with :ok <- validate_operands(key, expected, replacement) do
      case safe(fn ->
             Persistence.compare_and_swap(
               config.store_name,
               config.backend,
               key,
               expected,
               replacement,
               config.backend_opts
             )
           end) do
        {:ok, {:ok, %Record{} = stored}} ->
          validate_cas_receipt(stored, expected, replacement)

        {:ok, {:error, :conflict}} ->
          {:error, :conflict}

        {:ok, {:error, :unsupported}} ->
          {:error, :unsupported}

        {:ok, {:error, _reason}} ->
          {:error, :unavailable}

        {:error, _reason} ->
          {:error, :unavailable}

        _other ->
          {:error, :unavailable}
      end
    end
  end

  defp validate_operands(key, :not_found, %Record{key: key, generation: 0, revision: 0}),
    do: :ok

  defp validate_operands(
         key,
         {:value, %Record{key: key, id: id, generation: generation, revision: revision}},
         %Record{key: key, id: id, generation: generation, revision: revision}
       )
       when is_binary(id) and id != "" and generation >= 1 and revision >= 1,
       do: :ok

  defp validate_operands(_key, _expected, _replacement), do: {:error, :malformed_record}

  defp validate_cas_receipt(
         %Record{
           key: key,
           id: id,
           generation: 1,
           revision: 1
         } = stored,
         :not_found,
         %Record{key: key, id: id} = replacement
       ),
       do: admit_replacement_receipt(stored, replacement)

  defp validate_cas_receipt(
         %Record{
           key: key,
           id: id,
           generation: generation,
           revision: stored_revision
         } = stored,
         {:value,
          %Record{
            key: key,
            id: id,
            generation: generation,
            revision: expected_revision
          }},
         %Record{key: key, id: id, generation: generation, revision: expected_revision} =
           replacement
       )
       when stored_revision == expected_revision + 1 do
    admit_replacement_receipt(stored, replacement)
  end

  defp validate_cas_receipt(_stored, _expected, _replacement),
    do: {:error, :malformed_record}

  defp admit_replacement_receipt(stored, replacement) do
    if stored.data === replacement.data and stored.metadata === replacement.metadata,
      do: {:ok, stored},
      else: {:error, :malformed_record}
  end

  defp safe(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
    _, _ -> {:error, :unavailable}
  end
end
