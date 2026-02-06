defmodule Arbor.Agent.TimingContextTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.TimingContext

  describe "compute/1" do
    test "computes nil for fresh state" do
      state = %{
        last_user_message_at: nil,
        last_assistant_output_at: nil,
        responded_to_last_user_message: true
      }

      result = TimingContext.compute(state)

      assert result.seconds_since_user_message == nil
      assert result.seconds_since_last_output == nil
      assert result.responded_to_last_user_message == true
      assert result.user_waiting == false
    end

    test "computes seconds since user message" do
      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120, :second)

      state = %{
        last_user_message_at: two_minutes_ago,
        last_assistant_output_at: nil,
        responded_to_last_user_message: true
      }

      result = TimingContext.compute(state)

      # Allow 2 seconds of tolerance for test execution
      assert result.seconds_since_user_message >= 119
      assert result.seconds_since_user_message <= 122
    end

    test "detects user waiting based on threshold" do
      three_minutes_ago = DateTime.add(DateTime.utc_now(), -180, :second)

      state = %{
        last_user_message_at: three_minutes_ago,
        last_assistant_output_at: nil,
        responded_to_last_user_message: false
      }

      result = TimingContext.compute(state)
      assert result.user_waiting == true
    end

    test "user not waiting when responded" do
      three_minutes_ago = DateTime.add(DateTime.utc_now(), -180, :second)

      state = %{
        last_user_message_at: three_minutes_ago,
        last_assistant_output_at: nil,
        responded_to_last_user_message: true
      }

      result = TimingContext.compute(state)
      assert result.user_waiting == false
    end

    test "user not waiting when recent message" do
      five_seconds_ago = DateTime.add(DateTime.utc_now(), -5, :second)

      state = %{
        last_user_message_at: five_seconds_ago,
        last_assistant_output_at: nil,
        responded_to_last_user_message: false
      }

      result = TimingContext.compute(state)
      assert result.user_waiting == false
    end
  end

  describe "to_markdown/1" do
    test "formats human-readable timing" do
      timing = %{
        seconds_since_user_message: 65,
        seconds_since_last_output: 30,
        responded_to_last_user_message: true,
        user_waiting: false
      }

      markdown = TimingContext.to_markdown(timing)

      assert markdown =~ "## Conversational Timing"
      assert markdown =~ "1 minutes ago"
      assert markdown =~ "30 seconds ago"
      assert markdown =~ "Responded to last message: yes"
      refute markdown =~ "waiting"
    end

    test "includes warning when user waiting" do
      timing = %{
        seconds_since_user_message: 180,
        seconds_since_last_output: nil,
        responded_to_last_user_message: false,
        user_waiting: true
      }

      markdown = TimingContext.to_markdown(timing)

      assert markdown =~ "waiting"
      assert markdown =~ "Responded to last message: no"
    end

    test "handles nil durations" do
      timing = %{
        seconds_since_user_message: nil,
        seconds_since_last_output: nil,
        responded_to_last_user_message: true,
        user_waiting: false
      }

      markdown = TimingContext.to_markdown(timing)
      assert markdown =~ "never"
    end

    test "formats hours for large durations" do
      timing = %{
        seconds_since_user_message: 7200,
        seconds_since_last_output: 3601,
        responded_to_last_user_message: true,
        user_waiting: false
      }

      markdown = TimingContext.to_markdown(timing)
      assert markdown =~ "2 hours ago"
      assert markdown =~ "1 hours ago"
    end
  end

  describe "on_user_message/1" do
    test "updates timing fields" do
      state = %{
        last_user_message_at: nil,
        responded_to_last_user_message: true,
        other_field: "preserved"
      }

      new_state = TimingContext.on_user_message(state)

      assert new_state.last_user_message_at != nil
      assert new_state.responded_to_last_user_message == false
      assert new_state.other_field == "preserved"
    end
  end

  describe "on_agent_output/1" do
    test "updates output timing fields" do
      state = %{
        last_assistant_output_at: nil,
        responded_to_last_user_message: false,
        other_field: "preserved"
      }

      new_state = TimingContext.on_agent_output(state)

      assert new_state.last_assistant_output_at != nil
      assert new_state.responded_to_last_user_message == true
      assert new_state.other_field == "preserved"
    end
  end
end
