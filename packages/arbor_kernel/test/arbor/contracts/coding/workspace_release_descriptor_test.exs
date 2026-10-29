defmodule Arbor.Contracts.Coding.WorkspaceReleaseDescriptorTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.WorkspaceReleaseDescriptor

  @moduletag :fast

  test "normalizes retained and removed public descriptors" do
    assert {:ok, retained} =
             WorkspaceReleaseDescriptor.normalize(%{
               workspace_release_status: :retained,
               workspace_expires_at: "2026-07-16T12:00:00+00:00"
             })

    assert retained == %{
             "workspace_release_status" => "retained",
             "workspace_expires_at" => "2026-07-16T12:00:00Z"
           }

    assert {:ok, %{"workspace_release_status" => "removed"}} =
             WorkspaceReleaseDescriptor.normalize(%{"workspace_release_status" => "removed"})

    for status <- ["discarded", "discard_pending"] do
      assert {:ok, %{"workspace_release_status" => ^status}} =
               WorkspaceReleaseDescriptor.normalize(%{"workspace_release_status" => status})
    end
  end

  test "requires the enum status and permits expiry only for retained workspaces" do
    refute WorkspaceReleaseDescriptor.valid?(%{})
    refute WorkspaceReleaseDescriptor.valid?(%{"workspace_release_status" => "pending"})

    refute WorkspaceReleaseDescriptor.valid?(%{
             "workspace_release_status" => "removed",
             "workspace_expires_at" => "2026-07-16T12:00:00Z"
           })
  end

  test "rejects invalid oversized and non-string expiry values" do
    for expiry <- [
          "not-a-timestamp",
          String.duplicate("2", 65),
          9_999_999_999_999_999_999,
          "2026-07-16T12:00:00Z\n"
        ] do
      refute WorkspaceReleaseDescriptor.valid?(%{
               "workspace_release_status" => "retained",
               "workspace_expires_at" => expiry
             })
    end
  end

  test "rejects unknown mixed duplicate malformed and improper objects without raising" do
    refute WorkspaceReleaseDescriptor.valid?(%{
             "workspace_release_status" => "retained",
             "workspace_id" => "authority"
           })

    refute WorkspaceReleaseDescriptor.valid?(%{
             "workspace_release_status" => "retained",
             workspace_release_status: :retained
           })

    malformed = [{:workspace_release_status, :retained}, :not_a_pair]
    improper = [{:workspace_release_status, :retained} | :not_a_list]

    assert {:error, _reason} = WorkspaceReleaseDescriptor.new(malformed)
    assert {:error, _reason} = WorkspaceReleaseDescriptor.new(improper)
    refute WorkspaceReleaseDescriptor.valid?(malformed)
    refute WorkspaceReleaseDescriptor.valid?(improper)
  end

  test "rejects oversized map and list objects before field normalization" do
    oversized_map = %{
      "workspace_release_status" => "retained",
      "workspace_expires_at" => "2026-07-16T12:00:00Z",
      "workspace_id" => "not-public"
    }

    assert {:error, {:invalid_workspace_release_descriptor, :object_too_large}} =
             WorkspaceReleaseDescriptor.new(oversized_map)

    oversized_list = [
      {"workspace_release_status", "retained"},
      {"workspace_expires_at", "2026-07-16T12:00:00Z"},
      {"workspace_id", "not-public"}
    ]

    assert {:error, {:invalid_workspace_release_descriptor, :object_too_large}} =
             WorkspaceReleaseDescriptor.new(oversized_list)
  end
end
