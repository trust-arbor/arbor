defmodule Arbor.Actions.Coding.BranchAuditCheckpointCoreTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.BranchAuditCheckpoint
  alias Arbor.Actions.Coding.BranchAuditCore, as: AuditCore
  alias Arbor.Actions.Coding.BranchAuditCheckpointCore, as: Core

  @moduletag :fast

  test "checkpoint schema round trips and does not match a changed scope" do
    scope = scope()
    cache = Core.empty(scope["repository"], scope["destination"], %{})

    assert {:ok, bytes} = Core.encode(cache)
    assert {:ok, decoded} = Core.decode_json(bytes)
    assert :ok = Core.validate(decoded)
    assert Core.scope_matches?(decoded, scope)

    changed = put_in(scope, ["destination", "oid"], String.duplicate("d", 40))
    refute Core.scope_matches?(decoded, changed)
  end

  test "duplicate keys and unsafe filesystem shapes fail closed", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "audit.checkpoint")
    scope = scope()

    assert {:error, :duplicate_checkpoint_key} =
             Core.decode_json(~s({"format":"one","format":"two"}))

    File.write!(path, "{}")
    File.chmod!(path, 0o600)
    assert {:error, _reason} = BranchAuditCheckpoint.load(path, scope)

    valid = Core.empty(scope["repository"], scope["destination"], %{})
    assert :ok = BranchAuditCheckpoint.write(path, valid)
    assert {:ok, _cache, :hit} = BranchAuditCheckpoint.load(path, scope)

    File.chmod!(path, 0o644)
    assert {:error, :insecure_checkpoint_permissions} = BranchAuditCheckpoint.load(path, scope)

    File.rm!(path)
    symlink = Path.join(tmp_dir, "audit.symlink")

    assert :ok =
             :file.make_symlink(
               String.to_charlist(Path.join(tmp_dir, "missing")),
               String.to_charlist(symlink)
             )

    assert {:error, :insecure_checkpoint_file} = BranchAuditCheckpoint.load(symlink, scope)

    File.rm!(symlink)
    File.write!(path, String.duplicate("x", Core.max_bytes() + 1))
    File.chmod!(path, 0o600)
    assert {:error, :checkpoint_size_exceeded} = BranchAuditCheckpoint.load(path, scope)
  end

  test "structured failures keep exit 137 retryable and bounded" do
    storage =
      AuditCore.proof_failure(
        {:invalid_input,
         {:git_storage_validation_failed, ["--git-path", "objects"], 137, "secret"}}
      )

    command = AuditCore.proof_failure({:invalid_input, {:git_command_failed, 137}})

    assert storage == %{
             "category" => "git_storage_validation_failed",
             "detail" => "invalid_input",
             "code" => "exit_137",
             "retryable" => true
           }

    assert command == %{
             "category" => "git_command_failed",
             "detail" => "invalid_input",
             "code" => "137",
             "retryable" => true
           }
  end

  test "known Git boundary failures have distinct sanitized categories" do
    cases = [
      {{:invalid_input, {:git_storage_identity_changed, "/private/path"}},
       "git_storage_identity_changed", "identity_changed"},
      {{:invalid_input, {:invalid_git_storage_path, "objects", "/private/path"}},
       "invalid_git_storage_path", "path_rejected"},
      {{:invalid_input, {:invalid_git_storage_directory, "/private/path"}},
       "invalid_git_storage_directory", "directory_rejected"},
      {{:invalid_input, {:git_config_audit_failed, 137, "raw stdout"}}, "git_config_audit_failed",
       "exit_137"},
      {{:invalid_input, {:unsafe_git_configuration, [{"core.hookspath", "/private/path"}]}},
       "unsafe_git_configuration", "unsafe_configuration"},
      {{:invalid_input, :invalid_git_output}, "invalid_git_output", "malformed"},
      {{:invalid_input, :output_limit}, "output_limit", "limit_exceeded"},
      {{:range_too_large, :patch_bytes, 4_194_304}, "range_too_large", "4194304"},
      {{:range_too_large, :patch_evidence_bytes, 33_554_432}, "range_too_large", "33554432"}
    ]

    for {reason, category, code} <- cases do
      failure = AuditCore.proof_failure(reason)
      assert failure["category"] == category
      assert failure["code"] == code
      assert failure["retryable"] == (category != "range_too_large")

      assert failure["detail"] in [
               "storage",
               "config",
               "git_output",
               "patch_bytes",
               "patch_evidence_bytes"
             ]
    end

    assert AuditCore.proof_failure(:arbitrary_unknown_shape) == %{
             "category" => "unknown",
             "detail" => "unknown",
             "code" => "unknown",
             "retryable" => true
           }
  end

  defp scope do
    %{
      "policy_version" => Core.policy_version(),
      "repository" => %{"identity" => "/repo/.git", "path" => "/repo"},
      "destination" => %{"ref" => "refs/heads/main", "oid" => String.duplicate("b", 40)}
    }
  end
end
