defmodule Arbor.Persistence.SQL.ContractBindingSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Persistence.ContractProviders
  alias Arbor.Persistence.Contracts.Record
  alias Arbor.Persistence.QueryableStore.Postgres
  alias Arbor.Persistence.Schemas.Record, as: RecordSchema

  defmodule ForeignRecord do
    defstruct [:id, :key, :data, :metadata, :generation, :revision, :inserted_at, :updated_at]
  end

  defmodule ForeignFilter do
    defstruct conditions: [], since: nil, until: nil, order_by: nil, limit: nil, offset: nil
  end

  defmodule RepoProbe do
    def __adapter__, do: Ecto.Adapters.SQLite3

    def query(_sql, _parameters) do
      send(self(), :sql_effect_dispatched)
      {:error, :unexpected_sql_effect}
    end

    def one(_query) do
      # A changed global selector must not reinterpret a result halfway through
      # the operation, or override the storage owner's inherited binding.
      Application.put_env(:arbor_persistence, :contract_modules, %{})

      %Arbor.Persistence.Schemas.Record{
        id: "rec_binding",
        key: "binding",
        data: %{"value" => 1},
        metadata: %{},
        generation: 2,
        revision: 3,
        inserted_at: ~U[2026-10-27 00:00:00.000000Z],
        updated_at: ~U[2026-10-27 00:00:00.000000Z]
      }
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_persistence, :contract_modules)
    Application.delete_env(:arbor_persistence, :contract_modules)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_persistence, :contract_modules, value)
        :error -> Application.delete_env(:arbor_persistence, :contract_modules)
      end
    end)

    :ok
  end

  test "security regression: foreign record/filter lookalikes cannot dispatch SQL effects" do
    foreign = %ForeignRecord{id: "rec_foreign", key: "binding", data: %{}}

    assert {:error, :invalid_record} =
             Postgres.put("binding", foreign, name: :binding, repo: RepoProbe)

    assert {:error, :invalid_record} =
             Postgres.compare_and_swap("binding", :not_found, foreign,
               name: :binding,
               repo: RepoProbe
             )

    assert {:error, :conflict} =
             Postgres.compare_and_delete("binding", foreign, name: :binding, repo: RepoProbe)

    assert {:error, :invalid_filter} =
             Postgres.query(%ForeignFilter{}, name: :binding, repo: RepoProbe)

    refute_received :sql_effect_dispatched
  end

  test "security regression: a partial provider selector fails before SQL dispatch" do
    record = Record.new("binding", %{})
    Application.put_env(:arbor_persistence, :contract_modules, %{record: Record})

    assert {:error, {:put_failed, %ArgumentError{}}} =
             Postgres.put("binding", record, name: :binding, repo: RepoProbe)

    refute_received :sql_effect_dispatched
  end

  test "captured record identity survives a global change during Repo execution" do
    assert {:ok, %Record{generation: 2, revision: 3} = record} =
             Postgres.get("binding", name: :binding, repo: RepoProbe)

    assert record.id == "rec_binding"
    assert record.data == %{"value" => 1}
  end

  test "SQL inherits the storage owner's pinned contract identity" do
    bindings = ContractProviders.capture!()
    Application.put_env(:arbor_persistence, :contract_modules, %{})

    assert {:ok, %Record{key: "binding"}} =
             ContractProviders.with_bindings(bindings, fn ->
               Postgres.get("binding", name: :binding, repo: RepoProbe)
             end)

    assert %Record{} = RecordSchema.to_record(%RecordSchema{key: "binding"}, bindings)
  end
end
