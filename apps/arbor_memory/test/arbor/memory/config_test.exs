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
