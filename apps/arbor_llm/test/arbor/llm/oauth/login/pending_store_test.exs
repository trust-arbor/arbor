defmodule Arbor.LLM.OAuth.Login.PendingStoreTest do
  @moduledoc """
  Focused, non-security-framed correctness tests for PendingStore's closed
  issue/take round trip, one-shot consumption, and handle-shape validation.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.OAuth.Login.PendingStore

  setup do
    snapshot = :sys.get_state(PendingStore)
    on_exit(fn -> :sys.replace_state(PendingStore, fn _ -> snapshot end) end)
    :ok
  end

  defp future_deadline, do: System.monotonic_time(:millisecond) + 60_000

  test "issue_openai/2 returns a 43-character url-safe base64 handle with minted PKCE metadata" do
    assert {:ok, issuance} = PendingStore.issue_openai(:port_1455, future_deadline())

    assert byte_size(issuance.handle) == 43
    assert issuance.handle =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert is_binary(issuance.state)
    assert is_binary(issuance.code_challenge)
    assert issuance.state != ""
    assert issuance.code_challenge != ""
  end

  test "issue_xai/3 returns a 43-character url-safe base64 handle" do
    assert {:ok, issuance} = PendingStore.issue_xai("device", 5, future_deadline())
    assert byte_size(issuance.handle) == 43
    assert issuance.handle =~ ~r/\A[A-Za-z0-9_-]{43}\z/
  end

  test "take_openai/1 is a one-shot: the second take on the same handle fails" do
    {:ok, issuance} = PendingStore.issue_openai(:port_1455, future_deadline())

    assert {:ok, %{state: _state}} = PendingStore.take_openai(issuance.handle)
    assert {:error, :not_found} = PendingStore.take_openai(issuance.handle)
  end

  test "take_xai/1 is a one-shot: the second take on the same handle fails" do
    {:ok, issuance} = PendingStore.issue_xai("device", 5, future_deadline())

    assert {:ok, %{device_code: "device"}} = PendingStore.take_xai(issuance.handle)
    assert {:error, :not_found} = PendingStore.take_xai(issuance.handle)
  end

  test "an openai handle cannot be consumed via take_xai/1 and vice versa" do
    {:ok, openai_issuance} = PendingStore.issue_openai(:port_1455, future_deadline())
    {:ok, xai_issuance} = PendingStore.issue_xai("device", 5, future_deadline())

    assert {:error, :not_found} = PendingStore.take_xai(openai_issuance.handle)
    assert {:error, :not_found} = PendingStore.take_openai(xai_issuance.handle)
    assert {:ok, %{state: _state}} = PendingStore.take_openai(openai_issuance.handle)
    assert {:ok, %{device_code: _code}} = PendingStore.take_xai(xai_issuance.handle)
  end

  test "security regression: generic secret-bearing insertion APIs are not exposed" do
    refute function_exported?(PendingStore, :put_openai, 1)
    refute function_exported?(PendingStore, :put_xai, 1)
  end

  test "security regression: issue_openai/2 accepts only pinned redirect selectors" do
    assert {:ok, _} = PendingStore.issue_openai(:port_1455, future_deadline())
    assert {:ok, _} = PendingStore.issue_openai(:port_1457, future_deadline())

    for selector <- [:not_a_real_port, "http://evil.example/callback", nil, %{}] do
      assert {:error, :invalid_pending_value} =
               PendingStore.issue_openai(selector, future_deadline())
    end
  end

  test "security regression: issue_xai/3 bounds opaque device data and polling interval" do
    assert {:ok, _} = PendingStore.issue_xai(String.duplicate("a", 2_048), 1, future_deadline())
    assert {:ok, _} = PendingStore.issue_xai("device", 3_600, future_deadline())

    for device_code <- [
          "",
          "   ",
          "line\nbreak",
          <<0xFF>>,
          String.duplicate("a", 2_049),
          nil
        ] do
      assert {:error, :invalid_pending_value} =
               PendingStore.issue_xai(device_code, 5, future_deadline())
    end

    for interval <- [0, -1, 3_601, 1.5, nil] do
      assert {:error, :invalid_pending_value} =
               PendingStore.issue_xai("device", interval, future_deadline())
    end
  end

  test "issue functions return closed errors for malformed deadlines" do
    for deadline <- [nil, "later", 1.5, %{}] do
      assert {:error, :invalid_pending_deadline} =
               PendingStore.issue_openai(:port_1455, deadline)

      assert {:error, :invalid_pending_deadline} =
               PendingStore.issue_xai("device", 5, deadline)
    end
  end

  test "take_*/1 rejects malformed handles without reaching the GenServer" do
    for bad <- [
          "too-short",
          String.duplicate("a", 44),
          String.duplicate("a", 42) <> "!",
          nil,
          123,
          %{}
        ] do
      assert {:error, :not_found} = PendingStore.take_openai(bad)
      assert {:error, :not_found} = PendingStore.take_xai(bad)
    end
  end

  test "take_*/1 reports an already-past deadline as expired and still consumes the entry" do
    {:ok, issuance} = PendingStore.issue_openai(:port_1455, future_deadline())

    :sys.replace_state(PendingStore, fn state ->
      put_in(
        state,
        [:openai, issuance.handle, :deadline_ms],
        System.monotonic_time(:millisecond) - 1
      )
    end)

    assert {:error, :expired} = PendingStore.take_openai(issuance.handle)
    assert {:error, :not_found} = PendingStore.take_openai(issuance.handle)
  end

  test "issue_openai/2 rejects deadlines that are not strictly future or exceed TTL" do
    now = System.monotonic_time(:millisecond)

    assert {:error, :invalid_pending_deadline} = PendingStore.issue_openai(:port_1455, now)
    assert {:error, :invalid_pending_deadline} = PendingStore.issue_openai(:port_1455, now - 1)

    assert {:error, :invalid_pending_deadline} =
             PendingStore.issue_openai(:port_1455, now + 86_400_000 + 60_000)

    assert {:ok, _} = PendingStore.issue_openai(:port_1455, now + 5_000)
  end

  test "issue_xai/3 rejects deadlines that are not strictly future or exceed TTL" do
    now = System.monotonic_time(:millisecond)

    assert {:error, :invalid_pending_deadline} = PendingStore.issue_xai("device", 5, now)
    assert {:error, :invalid_pending_deadline} = PendingStore.issue_xai("device", 5, now - 1)

    assert {:error, :invalid_pending_deadline} =
             PendingStore.issue_xai("device", 5, now + 86_400_000 + 60_000)

    assert {:ok, _} = PendingStore.issue_xai("device", 5, now + 5_000)
  end
end
