defmodule Arbor.Actions.Coding.ValidationRuntimeAdmissionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.Coding.ValidationRuntimeAdmissionCore

  defmodule FakeRuntime do
    @moduledoc false

    def validation_runtime_status do
      Process.get(:validation_runtime_status, %{
        "state" => "unavailable",
        "reason" => nil,
        "driver" => "unavailable"
      })
    end

    def validation_runtime_probe do
      send(Process.get(:validation_runtime_test_pid, self()), :probed)

      Process.get(
        :validation_runtime_probe,
        {:error, :validation_runtime_unavailable}
      )
    end
  end

  setup do
    previous = Application.get_env(:arbor_actions, :validation_runtime_module)
    Application.put_env(:arbor_actions, :validation_runtime_module, FakeRuntime)
    Process.put(:validation_runtime_test_pid, self())

    on_exit(fn ->
      restore_env(:validation_runtime_module, previous)
      Process.delete(:validation_runtime_status)
      Process.delete(:validation_runtime_probe)
      Process.delete(:validation_runtime_test_pid)
    end)

    :ok
  end

  describe "ValidationRuntimeAdmissionCore.observe/3" do
    test "projects only driver, state, probe, and host_os" do
      status = %{
        "state" => "pinned",
        "driver" => "podman",
        "reason" => nil,
        "image_digest" => "sha256:" <> String.duplicate("a", 64),
        "path" => "/usr/bin/podman"
      }

      assert {:ok, envelope} =
               ValidationRuntimeAdmissionCore.observe(status, {:ok, status}, "linux")

      assert envelope == %{
               "driver" => "podman",
               "state" => "pinned",
               "probe" => "passed",
               "host_os" => "linux"
             }

      refute inspect(envelope) =~ "sha256"
      refute inspect(envelope) =~ "/usr/bin"
    end

    test "maps oci to podman and unsupported to unavailable" do
      status = %{"state" => "unsupported", "driver" => "oci"}

      assert {:ok, envelope} =
               ValidationRuntimeAdmissionCore.observe(status, :skipped, "linux")

      assert envelope["driver"] == "podman"
      assert envelope["state"] == "unavailable"
      assert envelope["probe"] == "skipped"
    end

    test "does not copy probe error terms" do
      status = %{"state" => "pinned", "driver" => "podman"}

      assert {:ok, envelope} =
               ValidationRuntimeAdmissionCore.observe(
                 status,
                 {:error, {:image_missing, "/var/lib/containers"}},
                 "linux"
               )

      assert envelope["probe"] == "failed"
      refute inspect(envelope) =~ "/var/lib"
    end

    test "projects a closed nonzero-exit tail without host paths or digests" do
      status = %{"state" => "pinned", "driver" => "podman"}

      assert {:ok, envelope} =
               ValidationRuntimeAdmissionCore.observe(
                 status,
                 {:error,
                  {:probe_nonzero_exit,
                   %{
                     exit_code: 2,
                     output_tail:
                       "runtime/cgo: pthread_create failed: Operation not permitted at /home/arbor/.local"
                   }}},
                 "linux"
               )

      assert envelope["probe"] == "failed"
      assert envelope["probe_exit_code"] == "2"
      assert envelope["probe_output_tail"] =~ "pthread_create"
      assert envelope["probe_output_tail"] =~ "runtime/cgo"
      refute envelope["probe_output_tail"] =~ "/home"
      refute inspect(envelope) =~ "sha256"
    end

    test "maps baseline authority unavailable to failed_starting without a host path" do
      status = %{"state" => "pinned", "driver" => "podman"}

      assert {:ok, envelope} =
               ValidationRuntimeAdmissionCore.observe(
                 status,
                 {:error, :linux_dependency_baseline_authority_unavailable},
                 "linux"
               )

      assert envelope["probe"] == "failed_starting"
      refute inspect(envelope) =~ "linux_dependency"
    end

    test "maps untrusted HOME to a closed probe label without a host path" do
      status = %{"state" => "pinned", "driver" => "podman"}

      assert {:ok, envelope} =
               ValidationRuntimeAdmissionCore.observe(
                 status,
                 {:error, :untrusted_home},
                 "linux"
               )

      assert envelope["probe"] == "failed_untrusted_home"
      refute inspect(envelope) =~ "/home"
    end

    test "rejects digest-like drivers" do
      status = %{"state" => "pinned", "driver" => "sha256:" <> String.duplicate("b", 64)}

      assert {:error, :malformed} =
               ValidationRuntimeAdmissionCore.observe(status, {:ok, %{}}, "linux")
    end
  end

  describe "Arbor.Actions.coding_validation_runtime_admission/0" do
    test "unconfigured status skips probe" do
      Process.put(:validation_runtime_status, %{
        "state" => "unavailable",
        "driver" => "unavailable"
      })

      assert {:ok, envelope} = Arbor.Actions.coding_validation_runtime_admission()
      assert envelope["state"] == "unavailable"
      assert envelope["probe"] == "skipped"
      assert envelope["host_os"] in ["linux", "macos", "unknown"]
      refute_received :probed
    end

    test "pinned status probes and returns podman on success" do
      Process.put(:validation_runtime_status, %{
        "state" => "pinned",
        "driver" => "podman"
      })

      Process.put(
        :validation_runtime_probe,
        {:ok, %{"state" => "available", "driver" => "podman"}}
      )

      assert {:ok, envelope} = Arbor.Actions.coding_validation_runtime_admission()
      assert envelope["state"] == "pinned"
      assert envelope["driver"] == "podman"
      assert envelope["probe"] == "passed"
      assert_received :probed
    end

    test "pinned probe failure is failed not skipped" do
      Process.put(:validation_runtime_status, %{
        "state" => "pinned",
        "driver" => "apple_container"
      })

      Process.put(:validation_runtime_probe, {:error, :apple_container_unavailable})

      assert {:ok, envelope} = Arbor.Actions.coding_validation_runtime_admission()
      assert envelope["driver"] == "apple_container"
      assert envelope["probe"] == "failed"
      assert_received :probed
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
