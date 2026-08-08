defmodule Arbor.Memory.MutationAdmission.RuntimeIdentity do
  @moduledoc false

  @table :arbor_memory_mutation_admission_runtime
  @key :runtime_fp
  @heir_data :arbor_memory_mutation_admission_runtime
  @hash_hex_length 64

  @spec bootstrap() :: {:ok, String.t()} | {:error, atom()}
  def bootstrap do
    with {:ok, controller} <- application_controller() do
      case :ets.whereis(@table) do
        :undefined -> create(controller)
        _table -> read_validated(controller, :bootstrap)
      end
    end
  end

  @spec current() :: {:ok, String.t()} | {:error, atom()}
  def current do
    with {:ok, controller} <- application_controller() do
      read_validated(controller, :current)
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) and byte_size(value) == @hash_hex_length do
    value == String.downcase(value) and String.match?(value, ~r/\A[0-9a-f]+\z/)
  end

  def valid?(_value), do: false

  defp create(controller) do
    table =
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        {:heir, controller, @heir_data},
        read_concurrency: true
      ])

    fingerprint = mint()
    true = :ets.insert_new(table, {@key, fingerprint})

    case validate_table(controller, :created) do
      :ok -> {:ok, fingerprint}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> read_validated(controller, :bootstrap)
  end

  defp read_validated(controller, mode) do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :runtime_identity_unavailable}

      table ->
        with :ok <- validate_table(controller, mode),
             [{@key, fingerprint}] <- :ets.lookup(table, @key),
             true <- valid?(fingerprint) do
          {:ok, fingerprint}
        else
          _ -> {:error, :invalid_runtime_identity}
        end
    end
  rescue
    ArgumentError -> {:error, :runtime_identity_unavailable}
  end

  defp validate_table(controller, mode) do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :runtime_identity_unavailable}

      table ->
        owner = :ets.info(table, :owner)
        heir = :ets.info(table, :heir)

        if :ets.info(table, :name) == @table and
             :ets.info(table, :type) == :set and
             :ets.info(table, :protection) == :protected and
             :ets.info(table, :size) == 1 and
             valid_owner?(mode, owner, heir, controller) do
          :ok
        else
          {:error, :invalid_runtime_identity_authority}
        end
    end
  end

  defp valid_owner?(:created, owner, heir, controller),
    do: owner == self() and heir == controller

  # A prior Memory application owner transfers the table to the BEAM-lifetime
  # controller when that application stops. No other existing owner is trusted
  # during bootstrap.
  defp valid_owner?(:bootstrap, owner, _heir, controller), do: owner == controller

  # During an active application lifetime the application master owns the table
  # and the controller is its exact heir; after a restart the controller owns it.
  defp valid_owner?(:current, owner, heir, controller),
    do: owner == controller or heir == controller

  defp valid_owner?(_mode, _owner, _heir, _controller), do: false

  defp application_controller do
    case Process.whereis(:application_controller) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :runtime_identity_unavailable}
    end
  end

  defp mint do
    :crypto.hash(
      :sha256,
      "arbor.memory.mutation_admission.runtime:v1" <> :crypto.strong_rand_bytes(32)
    )
    |> Base.encode16(case: :lower)
  end
end
