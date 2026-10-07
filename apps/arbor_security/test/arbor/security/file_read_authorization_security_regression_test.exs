defmodule Arbor.Security.FileReadAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag security: :regression
  @moduletag spec: "SSEC-015"

  alias Arbor.Security
  alias Arbor.Security.FileGuard

  defmodule CapturingFileGuard do
    @moduledoc false

    def prepare_read_for_capability(path, capability) do
      send(self(), {:descriptor_read_capability, path, capability.id, capability.resource_uri})
      {:error, :path_changed}
    end

    def validate_opened_read_for_capability(_opened_path, _root, _capability), do: :ok

    def authorize(_principal, _path, _operation) do
      send(self(), :second_capability_lookup)
      {:error, :must_not_reselect_capability}
    end

    def normalize_uri_path_for_capability(_resource, _capability) do
      send(self(), :path_only_normalization)
      {:error, :must_not_split_check_from_open}
    end
  end

  defmodule SwappingFileGuard do
    @moduledoc false

    def prepare_read_for_capability(path, capability) do
      with {:ok, plan} <-
             Arbor.Security.FileGuard.prepare_read_for_capability(path, capability) do
        %{replacement: replacement} =
          Application.fetch_env!(:arbor_security, :file_read_swap_fixture)

        File.rm!(path)
        File.ln_s!(replacement, path)
        send(self(), {:swapped_after_prepare, path, replacement})
        {:ok, plan}
      end
    end

    def validate_opened_read_for_capability(opened_path, root, capability) do
      send(self(), {:validated_before_stream, opened_path})

      Arbor.Security.FileGuard.validate_opened_read_for_capability(
        opened_path,
        root,
        capability
      )
    end

    def authorize(principal, path, operation),
      do: Arbor.Security.FileGuard.authorize(principal, path, operation)

    def normalize_uri_path_for_capability(resource, capability),
      do: Arbor.Security.FileGuard.normalize_uri_path_for_capability(resource, capability)
  end

  defmodule RewritingFileGuard do
    @moduledoc false

    def prepare_read_for_capability(path, capability),
      do: Arbor.Security.FileGuard.prepare_read_for_capability(path, capability)

    def validate_opened_read_for_capability(opened_path, root, capability) do
      with :ok <-
             Arbor.Security.FileGuard.validate_opened_read_for_capability(
               opened_path,
               root,
               capability
             ) do
        replacement =
          Application.fetch_env!(:arbor_security, :file_read_rewrite_fixture)

        File.write!(opened_path, replacement)
        :ok
      end
    end

    def authorize(principal, path, operation),
      do: Arbor.Security.FileGuard.authorize(principal, path, operation)

    def normalize_uri_path_for_capability(resource, capability),
      do: Arbor.Security.FileGuard.normalize_uri_path_for_capability(resource, capability)
  end

  defmodule RootSwappingFileGuard do
    @moduledoc false

    def prepare_read_for_capability(path, capability) do
      with {:ok, plan} <-
             Arbor.Security.FileGuard.prepare_read_for_capability(path, capability) do
        %{root: root, pinned_root: pinned_root, replacement_root: replacement_root} =
          Application.fetch_env!(:arbor_security, :file_read_root_swap_fixture)

        File.rename!(root, pinned_root)
        File.rename!(replacement_root, root)
        send(self(), {:root_swapped_after_prepare, root, pinned_root})
        {:ok, plan}
      end
    end

    def validate_opened_read_for_capability(opened_path, root, capability) do
      send(self(), {:unexpected_root_swap_validation, opened_path})

      Arbor.Security.FileGuard.validate_opened_read_for_capability(
        opened_path,
        root,
        capability
      )
    end

    def authorize(principal, path, operation),
      do: Arbor.Security.FileGuard.authorize(principal, path, operation)

    def normalize_uri_path_for_capability(resource, capability),
      do: Arbor.Security.FileGuard.normalize_uri_path_for_capability(resource, capability)
  end

  setup do
    previous = Application.get_env(:arbor_security, :file_guard_module)
    Application.put_env(:arbor_security, :file_guard_module, CapturingFileGuard)

    on_exit(fn ->
      restore_env(:file_guard_module, previous)
    end)

    :ok
  end

  @tag :security_regression
  test "security regression: authorized read opens with AuthDecision's exact selected capability" do
    principal = "agent_file_read_#{System.unique_integer([:positive])}"

    root =
      Path.join(System.tmp_dir!(), "file-read-capability-#{System.unique_integer([:positive])}")

    path = Path.join(root, "candidate.txt")
    exact_resource = FileGuard.resource_uri(:read, path)

    {:ok, exact} =
      Security.grant_fixture(
        principal: principal,
        resource: exact_resource,
        session_id: "session_file_read",
        task_id: "task_file_read"
      )

    {:ok, broad} =
      Security.grant_fixture(
        principal: principal,
        resource: FileGuard.resource_uri(:read, root <> "/**")
      )

    on_exit(fn ->
      Security.revoke_fixture(exact.id)
      Security.revoke_fixture(broad.id)
    end)

    assert {:error, :path_changed} =
             Security.read_authorized_file(principal, path,
               verify_identity: false,
               exact_capability_id: exact.id,
               session_id: "session_file_read",
               task_id: "task_file_read"
             )

    assert_receive {:descriptor_read_capability, ^path, exact_id, ^exact_resource}
    assert exact_id == exact.id
    refute_received :second_capability_lookup
    refute_received :path_only_normalization
  end

  @tag :security_regression
  test "security regression: workspace-relative authorization cannot diverge from the execution path" do
    principal = "agent_workspace_read_#{System.unique_integer([:positive])}"

    workspace =
      Path.join(System.tmp_dir!(), "file-read-workspace-#{System.unique_integer([:positive])}")

    expected_path = Path.join([workspace, "etc", "passwd"])
    File.mkdir_p!(Path.dirname(expected_path))
    File.write!(expected_path, "workspace-file")
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:error, :absolute_file_path_required} =
             Security.read_authorized_file(principal, "etc/passwd",
               verify_identity: false,
               workspace: workspace
             )

    refute_received {:descriptor_read_capability, ^expected_path, _, _}
    refute_received :second_capability_lookup
    refute_received :path_only_normalization
  end

  @tag :security_regression
  test "security regression: an unscoped relative read path fails closed" do
    assert {:error, :absolute_file_path_required} =
             Security.read_authorized_file("agent_relative_read", "etc/passwd",
               verify_identity: false
             )

    refute_received {:descriptor_read_capability, _, _, _}
  end

  @tag :security_regression
  @tag spec: "KSEC-012,SSEC-015"
  test "security regression: a post-prepare swap is denied before descriptor streaming" do
    Application.put_env(:arbor_security, :file_guard_module, SwappingFileGuard)

    principal = "agent_swap_read_#{System.unique_integer([:positive])}"
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    root = Path.join(System.tmp_dir!(), "file-read-swap-#{token}")
    candidate = Path.join(root, "candidate.txt")
    replacement = Path.join([root, "nested", "secret.txt"])
    File.mkdir_p!(Path.dirname(replacement))
    File.write!(candidate, "allowed")
    File.write!(replacement, "must-not-stream")
    on_exit(fn -> File.rm_rf!(root) end)

    previous_swap_fixture =
      Application.get_env(:arbor_security, :file_read_swap_fixture)

    Application.put_env(
      :arbor_security,
      :file_read_swap_fixture,
      %{replacement: replacement}
    )

    on_exit(fn ->
      restore_env(:file_read_swap_fixture, previous_swap_fixture)
    end)

    {:ok, capability} =
      Security.grant_fixture(
        principal: principal,
        resource: FileGuard.resource_uri(:read, root <> "/*")
      )

    on_exit(fn -> Security.revoke_fixture(capability.id) end)

    assert {:error, :no_capability} =
             Security.read_authorized_file(principal, candidate, verify_identity: false)

    assert_receive {:swapped_after_prepare, ^candidate, ^replacement}
    assert_receive {:validated_before_stream, opened_path}
    assert {:ok, canonical_replacement} = Arbor.Common.SafePath.resolve_real(replacement)
    assert opened_path == canonical_replacement
  end

  @tag :security_regression
  @tag spec: "KSEC-012,SSEC-015"
  test "security regression: the public read validates the opened descriptor before bytes flow" do
    Application.put_env(:arbor_security, :file_guard_module, RewritingFileGuard)

    principal = "agent_checked_read_#{System.unique_integer([:positive])}"
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    root = Path.join(System.tmp_dir!(), "file-read-checked-#{token}")
    candidate = Path.join(root, "candidate.txt")
    File.mkdir!(root)
    File.write!(candidate, "before-validation")
    on_exit(fn -> File.rm_rf!(root) end)

    previous_rewrite_fixture =
      Application.get_env(:arbor_security, :file_read_rewrite_fixture)

    Application.put_env(
      :arbor_security,
      :file_read_rewrite_fixture,
      "after-validation"
    )

    on_exit(fn ->
      restore_env(:file_read_rewrite_fixture, previous_rewrite_fixture)
    end)

    {:ok, capability} =
      Security.grant_fixture(
        principal: principal,
        resource: FileGuard.resource_uri(:read, candidate)
      )

    on_exit(fn -> Security.revoke_fixture(capability.id) end)

    assert {:ok, "after-validation", opened_path} =
             Security.read_authorized_file(principal, candidate,
               verify_identity: false,
               exact_capability_id: capability.id
             )

    assert {:ok, canonical_candidate} = Arbor.Common.SafePath.resolve_real(candidate)
    assert opened_path == canonical_candidate
  end

  @tag :security_regression
  @tag spec: "KSEC-012,SSEC-015"
  test "security regression: capability root identity stays bound after authorization" do
    Application.put_env(:arbor_security, :file_guard_module, RootSwappingFileGuard)

    principal = "agent_bound_root_#{System.unique_integer([:positive])}"
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    fixture = Path.join(System.tmp_dir!(), "file-read-root-swap-#{token}")
    root = Path.join(fixture, "authorized-root")
    pinned_root = Path.join(fixture, "authorized-root-pinned")
    replacement_root = Path.join(fixture, "replacement-root")
    candidate = Path.join(root, "candidate.txt")
    File.mkdir_p!(root)
    File.mkdir!(replacement_root)
    File.write!(candidate, "authorized-inode")
    File.write!(Path.join(replacement_root, "candidate.txt"), "replacement-secret")
    on_exit(fn -> File.rm_rf!(fixture) end)

    previous_root_swap_fixture =
      Application.get_env(:arbor_security, :file_read_root_swap_fixture)

    Application.put_env(
      :arbor_security,
      :file_read_root_swap_fixture,
      %{root: root, pinned_root: pinned_root, replacement_root: replacement_root}
    )

    on_exit(fn ->
      restore_env(:file_read_root_swap_fixture, previous_root_swap_fixture)
    end)

    {:ok, capability} =
      Security.grant_fixture(
        principal: principal,
        resource: FileGuard.resource_uri(:read, root <> "/**")
      )

    on_exit(fn -> Security.revoke_fixture(capability.id) end)

    assert {:error, :path_changed} =
             Security.read_authorized_file(principal, candidate, verify_identity: false)

    assert_receive {:root_swapped_after_prepare, ^root, ^pinned_root}
    refute_received {:unexpected_root_swap_validation, _opened_path}
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
