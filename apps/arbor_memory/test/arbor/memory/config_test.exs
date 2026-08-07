defmodule Arbor.Memory.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.Config

  @moduletag :fast

  test "normalizes a closed event log target" do
    assert {:ok,
            %{
              name: :memory_archive,
              backend: Arbor.Persistence.EventLog.Ecto,
              opts: [repo: Arbor.Persistence.Repo]
            }} =
             Config.normalize_event_log_target(
               name: :memory_archive,
               backend: Arbor.Persistence.EventLog.Ecto,
               opts: [repo: Arbor.Persistence.Repo]
             )
  end

  test "defaults maintenance archives to a target that durability admission rejects" do
    original = Application.fetch_env(:arbor_memory, :maintenance_archive_target)
    Application.delete_env(:arbor_memory, :maintenance_archive_target)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:arbor_memory, :maintenance_archive_target, value)
        :error -> Application.delete_env(:arbor_memory, :maintenance_archive_target)
      end
    end)

    assert {:ok,
            %{
              name: :memory_events,
              backend: Arbor.Persistence.EventLog.ETS,
              opts: []
            }} = Config.maintenance_archive_target()
  end

  @tag packet: "VP-05D2C3I1A"
  test "mutation admission namespace is fixed and backend defaults disabled" do
    assert Config.fixed_mutation_admission_namespace() == :memory_mutation_admission
    assert Config.mutation_admission_namespace() == {:ok, :memory_mutation_admission}
    assert Config.mutation_admission_backend() == {:error, :disabled}
    assert Config.validate_mutation_admission_backend(nil) == {:error, :disabled}

    assert Config.validate_mutation_admission_backend(Arbor.Persistence.QueryableStore.Postgres) ==
             {:ok, Arbor.Persistence.QueryableStore.Postgres}

    assert Config.validate_mutation_admission_backend_opts(repo: Arbor.Persistence.Repo) ==
             {:ok, [repo: Arbor.Persistence.Repo]}

    assert Config.validate_mutation_admission_backend_opts(name: :x) ==
             {:error, :invalid_config}
  end

  test "rejects unknown, duplicate, and ambiguous target fields" do
    assert {:error, :invalid_event_log_target} =
             Config.normalize_event_log_target(%{
               name: :memory_archive,
               backend: Arbor.Persistence.EventLog.Ecto,
               extra: true
             })

    assert {:error, :invalid_event_log_target} =
             Config.normalize_event_log_target(
               name: :first,
               name: :second,
               backend: Arbor.Persistence.EventLog.Ecto
             )

    assert {:error, :invalid_event_log_target} =
             Config.normalize_event_log_target(%{
               "name" => :ambiguous,
               name: :memory_archive,
               backend: Arbor.Persistence.EventLog.Ecto
             })
  end
end
