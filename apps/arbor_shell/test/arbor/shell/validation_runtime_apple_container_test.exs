defmodule Arbor.Shell.ValidationRuntime.AppleContainerTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.SpawnCapableTimeout
  alias Arbor.Shell.ValidationRuntime.AppleContainer

  @moduletag :fast

  test "security regression: readiness runs full image admission before reporting available" do
    test_pid = self()

    prober = fn deadline_ms ->
      send(test_pid, {:probed, deadline_ms})
      {:error, :apple_container_image_policy_unavailable}
    end

    status_provider = fn ->
      flunk("status must not be reported after failed image admission")
    end

    assert {:error, :apple_container_image_policy_unavailable} =
             AppleContainer.probe_for_test(prober, status_provider)

    assert_receive {:probed, deadline_ms}
    assert deadline_ms == SpawnCapableTimeout.max_probe_deadline_ms()
  end

  test "successful full admission returns only the public runtime status" do
    admission = %{"private" => "admission evidence"}
    status = %{"state" => "pinned", "driver" => "apple_container"}

    assert {:ok, ^status} =
             AppleContainer.probe_for_test(fn _deadline -> {:ok, admission} end, fn -> status end)
  end

  test "readiness can impose a deadline below the execution probe ceiling" do
    test_pid = self()
    deadline_ms = Arbor.Shell.validation_runtime_readiness_probe_timeout_ms()
    status = %{"state" => "pinned", "driver" => "apple_container"}

    assert deadline_ms == 30_000
    assert deadline_ms < SpawnCapableTimeout.max_probe_deadline_ms()

    assert {:ok, ^status} =
             AppleContainer.probe_for_test(
               deadline_ms,
               fn observed_deadline ->
                 send(test_pid, {:readiness_deadline, observed_deadline})
                 {:ok, %{}}
               end,
               fn -> status end
             )

    assert_receive {:readiness_deadline, ^deadline_ms}
  end

  test "malformed probe and status results fail closed" do
    assert {:error, :apple_container_unavailable} =
             AppleContainer.probe_for_test(fn _deadline -> :ok end, fn -> %{} end)

    assert {:error, :apple_container_unavailable} =
             AppleContainer.probe_for_test(fn _deadline -> {:ok, %{}} end, fn -> :pinned end)

    assert {:error, :apple_container_unavailable} =
             AppleContainer.probe_for_test(
               fn _deadline -> {:ok, %{}} end,
               fn -> %{"state" => "unavailable"} end
             )

    assert {:error, :apple_container_unsupported} =
             AppleContainer.probe_for_test(
               fn _deadline -> {:ok, %{}} end,
               fn -> %{"state" => "unsupported"} end
             )
  end
end
