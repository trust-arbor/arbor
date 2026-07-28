defmodule Arbor.CommsTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms
  alias Arbor.Comms.PresenceTracker

  describe "channels/0" do
    test "returns list of enabled channels" do
      channels = Comms.channels()
      assert is_list(channels)
    end
  end

  describe "channel_info/1" do
    test "returns info for known channel" do
      info = Comms.channel_info(:signal)
      assert info.name == :signal
      assert is_integer(info.max_message_length)
    end

    test "returns error for unknown channel" do
      assert {:error, :unknown_channel} = Comms.channel_info(:nonexistent)
    end
  end

  describe "healthy?/0" do
    test "returns true" do
      assert Comms.healthy?()
    end
  end

  describe "send/4" do
    test "returns error for unknown channel" do
      assert {:error, {:unknown_channel, :nonexistent}} =
               Comms.send(:nonexistent, "+1234", "hello")
    end
  end

  describe "poll/1" do
    test "returns error for unknown channel" do
      assert {:error, {:unknown_channel, :nonexistent}} =
               Comms.poll(:nonexistent)
    end
  end

  describe "recent_messages/2" do
    test "returns empty list for channel with no history" do
      assert {:ok, []} = Comms.recent_messages(:nonexistent_channel)
    end
  end

  describe "interaction presence facade" do
    test "tracks and untracks a caller without exposing PresenceTracker" do
      user_id = "user_comms_facade_#{System.unique_integer([:positive])}"
      metadata = %{session_id: "session-facade"}

      assert {:ok, _ref} = Comms.track_presence(self(), user_id, :dashboard, metadata)

      assert_eventually(fn ->
        match?(
          [{:dashboard, %{session_id: "session-facade", joined_at: joined_at}}]
          when is_integer(joined_at),
          PresenceTracker.active_channels(user_id)
        )
      end)

      assert :ok = Comms.untrack_presence(self(), user_id, :dashboard)
      assert_eventually(fn -> PresenceTracker.active_channels(user_id) == [] end)
    end
  end

  describe "durable interaction payload validator" do
    alias Arbor.Contracts.Comms.Interaction

    test "accepts short operator prose with exact evidence in metadata" do
      design = String.duplicate("d", 12_700)
      work_packet_body = String.duplicate("w", 4_800)

      {:ok, interaction} =
        Interaction.new(%{
          request_id: "irq_design_phase_f_shape",
          kind: :approval,
          agent_id: "agent_phase_f",
          user_id: "operator_1",
          description:
            "Design checkpoint for task task-phase-f (attempt 1). " <>
              "Review metadata for the exact work packet, task, plan fingerprint, and design.",
          metadata: %{
            "task_id" => "task-phase-f",
            "task" => "Implement durable design checkpoint payload fix",
            "design" => design,
            "work_packet" => %{"body" => work_packet_body},
            "packet_digest" => "sha256:" <> String.duplicate("a", 64),
            "design_digest" => "sha256:" <> String.duplicate("b", 64)
          },
          resource_uri: "arbor://action/coding/design_checkpoint"
        })

      assert byte_size(interaction.description) < 1_024
      assert byte_size(design) == 12_700
      assert byte_size(work_packet_body) == 4_800
      assert :ok = Comms.validate_durable_interaction_payload(interaction)
    end

    test "rejects oversized description and oversized metadata aggregates" do
      # Durable ordinary-string ceiling is 16 KiB; stay clearly above it without
      # exposing a public limit accessor for callers to re-copy.
      oversized_description = String.duplicate("x", 20_000)

      {:ok, long_description} =
        Interaction.new(%{
          request_id: "irq_invalid_description",
          kind: :approval,
          agent_id: "agent_invalid",
          user_id: "operator_1",
          description: oversized_description,
          metadata: %{}
        })

      assert {:error, {:invalid_durable_interaction, {:invalid, :description}}} =
               Comms.validate_durable_interaction_payload(long_description)

      oversized_metadata = %{
        "a" => String.duplicate("x", 10_000),
        "b" => String.duplicate("x", 10_000),
        "c" => String.duplicate("x", 10_000),
        "d" => String.duplicate("x", 10_000)
      }

      {:ok, large_metadata} =
        Interaction.new(%{
          request_id: "irq_invalid_metadata",
          kind: :approval,
          agent_id: "agent_invalid",
          user_id: "operator_1",
          description: "Short operator prose",
          metadata: oversized_metadata
        })

      assert {:error, {:invalid_durable_interaction, :json_value_too_large}} =
               Comms.validate_durable_interaction_payload(large_metadata)
    end

    test "request_durable_interaction rejects invalid payloads before Authority" do
      {:ok, interaction} =
        Interaction.new(%{
          request_id: "irq_reject_before_authority",
          kind: :approval,
          agent_id: "agent_invalid",
          user_id: "operator_1",
          description: String.duplicate("x", 20_000),
          metadata: %{}
        })

      assert {:error, {:invalid_durable_interaction, {:invalid, :description}}} =
               Comms.request_durable_interaction(interaction,
                 owner_deadline_unix_ms: System.system_time(:millisecond) + 60_000
               )
    end
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        receive do
        after
          10 -> do_assert_eventually(fun, deadline)
        end
    end
  end
end
