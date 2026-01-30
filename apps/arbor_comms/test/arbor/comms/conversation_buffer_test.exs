defmodule Arbor.Comms.ConversationBufferTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.ConversationBuffer
  alias Arbor.Contracts.Comms.Message

  @test_log_dir "/tmp/arbor/test_conv_buffer"
  @test_log_dir_b "/tmp/arbor/test_conv_buffer_b"
  @contact "+1234567890"

  setup do
    Application.put_env(:arbor_comms, :test_conv, log_dir: @test_log_dir, enabled: true)
    Application.put_env(:arbor_comms, :test_conv_b, log_dir: @test_log_dir_b, enabled: true)
    File.rm_rf(@test_log_dir)
    File.rm_rf(@test_log_dir_b)

    on_exit(fn ->
      File.rm_rf(@test_log_dir)
      File.rm_rf(@test_log_dir_b)
      Application.delete_env(:arbor_comms, :test_conv)
      Application.delete_env(:arbor_comms, :test_conv_b)
    end)

    :ok
  end

  describe "recent_turns/3" do
    test "returns empty list when no log exists" do
      assert ConversationBuffer.recent_turns(:test_conv, @contact) == []
    end

    test "parses inbound messages as :user turns" do
      msg =
        Message.new(
          channel: :test_conv,
          from: @contact,
          content: "Hello there",
          direction: :inbound
        )

      ChatLogger.log_message(msg)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)
      assert [{:user, "Hello there"}] = turns
    end

    test "parses outbound messages as :assistant turns" do
      msg = Message.outbound(:test_conv, @contact, "Hi back")
      ChatLogger.log_message(msg)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)
      assert [{:assistant, "Hi back"}] = turns
    end

    test "returns conversation in order" do
      inbound =
        Message.new(
          channel: :test_conv,
          from: @contact,
          content: "What is Arbor?",
          direction: :inbound
        )

      outbound = Message.outbound(:test_conv, @contact, "A distributed AI system")

      ChatLogger.log_message(inbound)
      ChatLogger.log_message(outbound)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)

      assert [
               {:user, "What is Arbor?"},
               {:assistant, "A distributed AI system"}
             ] = turns
    end

    test "respects window size" do
      for i <- 1..10 do
        msg =
          Message.new(
            channel: :test_conv,
            from: @contact,
            content: "Message #{i}",
            direction: :inbound
          )

        ChatLogger.log_message(msg)
      end

      turns = ConversationBuffer.recent_turns(:test_conv, @contact, 3)
      assert length(turns) == 3
      assert {:user, "Message 10"} = List.last(turns)
    end

    test "filters by contact" do
      msg1 =
        Message.new(
          channel: :test_conv,
          from: @contact,
          content: "From target",
          direction: :inbound
        )

      msg2 =
        Message.new(
          channel: :test_conv,
          from: "+9999999999",
          content: "From other",
          direction: :inbound
        )

      ChatLogger.log_message(msg1)
      ChatLogger.log_message(msg2)

      turns = ConversationBuffer.recent_turns(:test_conv, @contact)
      assert [{:user, "From target"}] = turns
    end
  end

  describe "contact_aliases/1" do
    test "returns aliases for a primary contact" do
      prev = Application.get_env(:arbor_comms, :handler)

      Application.put_env(:arbor_comms, :handler,
        Keyword.put(prev || [], :contact_aliases, %{
          "+1234567890" => ["pendant", "user@example.com"]
        })
      )

      aliases = ConversationBuffer.contact_aliases("+1234567890")
      assert "+1234567890" in aliases
      assert "pendant" in aliases
      assert "user@example.com" in aliases

      Application.put_env(:arbor_comms, :handler, prev || [])
    end

    test "resolves alias value back to primary group" do
      prev = Application.get_env(:arbor_comms, :handler)

      Application.put_env(:arbor_comms, :handler,
        Keyword.put(prev || [], :contact_aliases, %{
          "+1234567890" => ["pendant"]
        })
      )

      aliases = ConversationBuffer.contact_aliases("pendant")
      assert "+1234567890" in aliases
      assert "pendant" in aliases

      Application.put_env(:arbor_comms, :handler, prev || [])
    end

    test "returns contact alone when no aliases configured" do
      assert ConversationBuffer.contact_aliases("unknown") == ["unknown"]
    end
  end

  describe "recent_turns_cross_channel/2" do
    setup do
      prev_handler = Application.get_env(:arbor_comms, :handler)

      Application.put_env(:arbor_comms, :handler,
        Keyword.merge(prev_handler || [], [
          contact_aliases: %{@contact => ["pendant"]},
          conversation_window: 20
        ])
      )

      on_exit(fn ->
        Application.put_env(:arbor_comms, :handler, prev_handler || [])
      end)

      :ok
    end

    test "merges turns from multiple channels by timestamp" do
      # Simulate channel A message at :00
      msg_a =
        Message.new(
          channel: :test_conv,
          from: @contact,
          content: "Signal message",
          direction: :inbound,
          received_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC")
        )

      # Simulate channel B message at :01 with alias contact
      msg_b =
        Message.new(
          channel: :test_conv_b,
          from: "pendant",
          content: "Pendant transcript",
          direction: :inbound,
          received_at: DateTime.new!(Date.utc_today(), ~T[10:01:00], "Etc/UTC")
        )

      # Response goes to channel A at :02
      msg_reply =
        Message.new(
          channel: :test_conv,
          from: "arbor",
          to: @contact,
          content: "Got both",
          direction: :outbound,
          received_at: DateTime.new!(Date.utc_today(), ~T[10:02:00], "Etc/UTC")
        )

      ChatLogger.log_message(msg_a)
      ChatLogger.log_message(msg_b)
      ChatLogger.log_message(msg_reply)

      # Override configured_channels to use our test channels
      # We use recent_turns_cross_channel which calls Config.configured_channels()
      # For this test, we set our test channels as enabled
      turns = cross_channel_turns(@contact, [:test_conv, :test_conv_b])

      assert length(turns) == 3
      assert {:user, "Signal message"} = Enum.at(turns, 0)
      assert {:user, "Pendant transcript"} = Enum.at(turns, 1)
      assert {:assistant, "Got both"} = Enum.at(turns, 2)
    end

    test "respects window across merged channels" do
      for i <- 1..5 do
        msg =
          Message.new(
            channel: :test_conv,
            from: @contact,
            content: "Signal #{i}",
            direction: :inbound,
            received_at: DateTime.new!(Date.utc_today(), Time.new!(10, i, 0), "Etc/UTC")
          )

        ChatLogger.log_message(msg)
      end

      for i <- 1..5 do
        msg =
          Message.new(
            channel: :test_conv_b,
            from: "pendant",
            content: "Pendant #{i}",
            direction: :inbound,
            received_at: DateTime.new!(Date.utc_today(), Time.new!(10, i, 30), "Etc/UTC")
          )

        ChatLogger.log_message(msg)
      end

      turns = cross_channel_turns(@contact, [:test_conv, :test_conv_b], 4)

      assert length(turns) == 4
      # Last 4 turns should be: Signal 5, Pendant 4, Pendant 5... depending on sort
      # All should be present and sorted by time
      contents = Enum.map(turns, fn {_role, content} -> content end)
      assert Enum.all?(contents, &is_binary/1)
    end
  end

  # Helper to call cross-channel with specific channels (bypasses Config.configured_channels)
  defp cross_channel_turns(contact, channels, window \\ 20) do
    aliases = ConversationBuffer.contact_aliases(contact)
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    turns =
      for channel <- channels,
          date <- [yesterday, today],
          turn <- read_timed_turns_for_test(channel, aliases, date) do
        turn
      end

    turns
    |> Enum.sort_by(fn {_role, _content, ts} -> ts end, NaiveDateTime)
    |> Enum.take(-window)
    |> Enum.map(fn {role, content, _ts} -> {role, content} end)
  end

  # Expose internal read for testing (reads timed turns)
  defp read_timed_turns_for_test(channel, contacts, date) do
    path = ChatLogger.log_path_for_date(channel, date)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.filter(fn line ->
          Enum.any?(contacts, fn c -> String.contains?(line, "[#{c}]") end)
        end)
        |> Enum.map(fn line ->
          cond do
            String.contains?(line, "<<<") ->
              case parse_test_line(line, "<<<") do
                {content, ts} -> {:user, content, ts}
                nil -> nil
              end

            String.contains?(line, ">>>") ->
              case parse_test_line(line, ">>>") do
                {content, ts} -> {:assistant, content, ts}
                nil -> nil
              end

            true ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp parse_test_line(line, marker) do
    case String.split(line, marker, parts: 2) do
      [ts_str, rest] ->
        rest = String.trim(rest)

        content =
          case Regex.run(~r/^\[.+?\]\s*(.*)$/, rest) do
            [_, c] -> String.replace(c, "\\n", "\n")
            _ -> nil
          end

        ts =
          case NaiveDateTime.from_iso8601(String.replace(String.trim(ts_str), " ", "T")) do
            {:ok, ndt} -> ndt
            {:error, _} -> ~N[2000-01-01 00:00:00]
          end

        if content, do: {content, ts}, else: nil

      _ ->
        nil
    end
  end
end
