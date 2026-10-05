defmodule Arbor.Comms.ConversationDirectoryTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @owner "human_directory_comms"
  @id "eng_11111111111111111111111111111111"

  defmodule Storage do
    def normalize_conversation_directory_options(opts),
      do: Arbor.Persistence.normalize_conversation_directory_options(opts)

    def list_user_conversation_records(owner, opts) do
      send(self(), {:directory_storage, owner, opts})
      result()
    end

    def read_user_conversation_record(owner, id) do
      send(self(), {:directory_reference, owner, id})
      result()
    end

    defp result do
      case Process.get(:directory_result) do
        :raise -> raise "private DB detail"
        :exit -> exit(:private_db_detail)
        :throw -> throw(:private_db_detail)
        result -> result
      end
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_comms, :conversation_directory_persistence_module)
    Application.put_env(:arbor_comms, :conversation_directory_persistence_module, Storage)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:arbor_comms, :conversation_directory_persistence_module, value)

        :error ->
          Application.delete_env(:arbor_comms, :conversation_directory_persistence_module)
      end
    end)

    :ok
  end

  test "public trusted directory validates closed owned records and pagination" do
    page = %{records: [record()], has_more: true, next_cursor: 1}
    Process.put(:directory_result, {:ok, page})
    assert {:ok, ^page} = Arbor.Comms.list_user_conversation_records(@owner, limit: 1)
    assert_receive {:directory_storage, @owner, [limit: 1]}
    Process.put(:directory_result, {:ok, record()})
    assert {:ok, %{engagement_id: @id}} = Arbor.Comms.read_user_conversation_record(@owner, @id)
  end

  test "security regression malformed recovered ownership visibility and fields fail closed" do
    for change <- [
          %{owner_tenant: "human_foreign"},
          %{visibility: "group"},
          %{scope: "channel"},
          %{status: "unknown"},
          %{engagement_id: "foreign"},
          %{metadata: %{secret: "private"}}
        ] do
      Process.put(
        :directory_result,
        {:ok, %{records: [Map.merge(record(), change)], has_more: false, next_cursor: nil}}
      )

      assert {:error, :conversation_unavailable} =
               Arbor.Comms.list_user_conversation_records(@owner)
    end
  end

  test "security regression invalid selectors fail before owner storage lookup" do
    for opts <- [[owner_tenant: "human_foreign"], [limit: 0], [cursor: -1], [limit: 1, limit: 2]] do
      assert {:error, :invalid_options} = Arbor.Comms.list_user_conversation_records(@owner, opts)
      refute_receive {:directory_storage, _, _}
    end
  end

  test "storage failures never become false empty directory or reference success" do
    for result <- [
          :raise,
          :exit,
          :throw,
          [],
          {:error, :private_db_error},
          {:ok, %{records: [], has_more: true, next_cursor: nil}}
        ] do
      Process.put(:directory_result, result)

      assert {:error, :conversation_unavailable} =
               Arbor.Comms.list_user_conversation_records(@owner)

      assert {:error, :conversation_unavailable} =
               Arbor.Comms.read_user_conversation_record(@owner, @id)
    end
  end

  test "security regression a reference cannot return another engagement" do
    Process.put(
      :directory_result,
      {:ok, %{record() | engagement_id: "eng_22222222222222222222222222222222"}}
    )

    assert {:error, :conversation_unavailable} =
             Arbor.Comms.read_user_conversation_record(@owner, @id)
  end

  defp record,
    do: %{
      engagement_id: @id,
      agent_id: "agent_directory_comms",
      owner_tenant: @owner,
      scope: "user",
      visibility: "private",
      status: "active",
      updated_at: ~U[2026-10-02 00:00:00Z]
    }
end
