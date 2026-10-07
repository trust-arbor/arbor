defmodule Mix.Tasks.Arbor.Scheduler.TasksTest do
  @moduledoc """
  Integration tests for the Phase 4 mix tasks:
    - `arbor.scheduler.sign_caps`
    - `arbor.scheduler.enroll_issuer`
    - `arbor.scheduler.audit_caps`

  Each task is exercised end-to-end: real identity, real
  IssuerRegistry/IdentityRegistry, real on-disk file writes. Uses
  `Mix.shell(Mix.Shell.Process)` to capture task output for assertion.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.{CapsFile, PipelinePaths}
  alias Arbor.Security

  @envelope_uri "arbor://fs/write/reports/**"

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, identity} = Identity.generate()
    :ok = Security.register_identity_fixture(identity)

    for operation <- [:register, :update] do
      {:ok, _capability} =
        Arbor.Security.grant_fixture(
          principal: identity.agent_id,
          resource: "arbor://security/issuer/#{operation}"
        )
    end

    tmp = System.tmp_dir!() |> Path.join("scheduler_tasks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    operator_key_path = Path.join(tmp, "operator.arbor.key")
    write_key_file(operator_key_path, identity)

    restore_env(:pipeline_roots)
    Application.put_env(:arbor_scheduler, :pipeline_roots, %{"test" => tmp})

    on_exit(fn ->
      Security.revoke_issuer_fixture(identity.agent_id, "test cleanup")
      Arbor.Security.revoke_all_fixture(identity.agent_id)
      Security.deregister_identity_fixture(identity.agent_id)
      File.rm_rf!(tmp)
    end)

    {:ok, identity: identity, tmp_dir: tmp, operator_key_path: operator_key_path}
  end

  describe "arbor.scheduler.enroll_issuer" do
    test "security regression: enrolls through an exact signed key-file proof", %{
      identity: identity,
      operator_key_path: operator_key_path
    } do
      Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
        "--issuer-id",
        identity.agent_id,
        "--key-file",
        operator_key_path,
        "--envelope-uri",
        @envelope_uri,
        "--reason",
        "test enrollment"
      ])

      assert_received {:mix_shell, :info, [msg]}
      assert msg == "Enrolled issuer:"

      entries = Security.list_issuers_fixture()
      entry = Enum.find(entries, &(&1.issuer_id == identity.agent_id))
      assert [env] = entry.max_envelope_caps
      assert env.resource_uri == @envelope_uri
      assert entry.status == :active
      assert entry.status_reason == "test enrollment"
    end

    test "fails with missing required option", %{identity: identity} do
      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
                 "--issuer-id",
                 identity.agent_id
                 # envelope-uri missing
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "missing_required_option"
      assert msg =~ "envelope_uri"
    end

    test "accepts multiple --envelope-uri flags", %{
      identity: identity,
      operator_key_path: operator_key_path
    } do
      Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
        "--issuer-id",
        identity.agent_id,
        "--key-file",
        operator_key_path,
        "--envelope-uri",
        "arbor://fs/read/reports/upstream-deps/**",
        "--envelope-uri",
        "arbor://fs/write/reports/upstream-deps-summary/**"
      ])

      entries = Security.list_issuers_fixture()
      entry = Enum.find(entries, &(&1.issuer_id == identity.agent_id))
      assert length(entry.max_envelope_caps) == 2

      uris = Enum.map(entry.max_envelope_caps, & &1.resource_uri)
      assert "arbor://fs/read/reports/upstream-deps/**" in uris
      assert "arbor://fs/write/reports/upstream-deps-summary/**" in uris
    end

    test "security regression: update uses a separately bound signed key-file proof", %{
      identity: identity,
      operator_key_path: operator_key_path
    } do
      Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
        "--issuer-id",
        identity.agent_id,
        "--key-file",
        operator_key_path,
        "--envelope-uri",
        "arbor://fs/write/reports/**"
      ])

      Mix.Tasks.Arbor.Scheduler.UpdateIssuerEnvelopes.run([
        "--issuer-id",
        identity.agent_id,
        "--key-file",
        operator_key_path,
        "--envelope-uri",
        "arbor://fs/read/code/**",
        "--envelope-uri",
        "arbor://fs/write/code/**",
        "--reason",
        "adding code review support"
      ])

      entries = Security.list_issuers_fixture()
      entry = Enum.find(entries, &(&1.issuer_id == identity.agent_id))
      uris = Enum.map(entry.max_envelope_caps, & &1.resource_uri)
      assert length(uris) == 2
      assert "arbor://fs/read/code/**" in uris
      assert "arbor://fs/write/code/**" in uris
      refute "arbor://fs/write/reports/**" in uris
      assert entry.status_reason == "adding code review support"
    end

    test "security regression: a valid key without issuer-mutation authority is refused", %{
      identity: target,
      tmp_dir: tmp_dir
    } do
      {:ok, attacker} = Identity.generate(name: "unprivileged issuer operator")
      :ok = Security.register_identity_fixture(attacker)
      on_exit(fn -> Security.deregister_identity_fixture(attacker.agent_id) end)
      attacker_key_path = Path.join(tmp_dir, "unprivileged-operator.arbor.key")
      write_key_file(attacker_key_path, attacker)

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
                 "--issuer-id",
                 target.agent_id,
                 "--key-file",
                 attacker_key_path,
                 "--envelope-uri",
                 @envelope_uri
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "issuer_mutation_unauthorized"
      assert {:error, :not_found} = Security.lookup_issuer(target.agent_id)
    end

    test "update_issuer_envelopes fails for unenrolled issuer", %{
      operator_key_path: operator_key_path
    } do
      bogus = "agent_8888888888888888888888888888888888888888888888888888888888888888"

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.UpdateIssuerEnvelopes.run([
                 "--issuer-id",
                 bogus,
                 "--key-file",
                 operator_key_path,
                 "--envelope-uri",
                 "arbor://fs/read/x"
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "not_found"
    end

    test "fails for unregistered identity", %{operator_key_path: operator_key_path} do
      bogus_id = "agent_9999999999999999999999999999999999999999999999999999999999999999"

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
                 "--issuer-id",
                 bogus_id,
                 "--key-file",
                 operator_key_path,
                 "--envelope-uri",
                 @envelope_uri
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "identity_not_found"
    end
  end

  describe "arbor.scheduler.sign_caps" do
    test "signs a well-formed unsigned caps file", %{identity: identity, tmp_dir: tmp_dir} do
      caps_path = Path.join(tmp_dir, "summary.caps.json")
      dot_path = Path.join(tmp_dir, "summary.dot")
      key_path = Path.join(tmp_dir, "test.arbor.key")
      File.write!(dot_path, "digraph Summary { start [shape=Mdiamond] }")

      File.write!(
        caps_path,
        Jason.encode!(%{
          "version" => 1,
          "issuer_id" => identity.agent_id,
          "capabilities" => [
            %{"resource_uri" => "arbor://fs/write/reports/upstream-deps-summary/**"}
          ],
          "signature" => ""
        })
      )

      write_key_file(key_path, identity)

      # Need the issuer enrolled for CapsFile.load to verify end-to-end.
      {:ok, envelope} =
        Capability.new(resource_uri: @envelope_uri, principal_id: identity.agent_id)

      :ok =
        Security.register_issuer_fixture(identity.agent_id, envelope, reason: "sign_caps test")

      Mix.Tasks.Arbor.Scheduler.SignCaps.run([
        "--key-file",
        key_path,
        "--workdir",
        tmp_dir,
        "--args-json",
        ~s({"mode":"summary"}),
        caps_path
      ])

      assert {:ok, attestation} = CapsFile.load(caps_path)
      assert attestation.version == 2
      assert attestation.pipeline_root == "test"
      assert attestation.pipeline_path == "summary.dot"
      assert attestation.initial_args == %{"mode" => "summary"}
      assert [%{resource_uri: uri}] = attestation.capabilities
      assert uri == "arbor://fs/write/reports/upstream-deps-summary/**"
    end

    test "regression: refuses to sign when key's agent_id doesn't match caps file issuer_id",
         %{identity: identity, tmp_dir: tmp_dir} do
      # The sign step verifies the operator isn't signing under the wrong
      # identity. Without this check, a stolen key could produce a signed
      # file ostensibly from someone else (the signature would still fail
      # at load time, but earlier failure with a clear error helps ops).
      caps_path = Path.join(tmp_dir, "mismatched.caps.json")
      dot_path = Path.join(tmp_dir, "mismatched.dot")
      key_path = Path.join(tmp_dir, "other.arbor.key")
      File.write!(dot_path, "digraph Mismatched { start [shape=Mdiamond] }")

      {:ok, other_identity} = Identity.generate()

      File.write!(
        caps_path,
        Jason.encode!(%{
          "version" => 1,
          "issuer_id" => identity.agent_id,
          "capabilities" => [%{"resource_uri" => "arbor://fs/write/reports/x"}],
          "signature" => ""
        })
      )

      write_key_file(key_path, other_identity)

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.SignCaps.run([
                 "--key-file",
                 key_path,
                 "--workdir",
                 tmp_dir,
                 "--args-json",
                 "{}",
                 caps_path
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "issuer_mismatch"
    end

    test "fails for missing key file", %{identity: identity, tmp_dir: tmp_dir} do
      caps_path = Path.join(tmp_dir, "any.caps.json")
      dot_path = Path.join(tmp_dir, "any.dot")
      File.write!(dot_path, "digraph Any { start [shape=Mdiamond] }")

      File.write!(
        caps_path,
        Jason.encode!(%{
          "version" => 1,
          "issuer_id" => identity.agent_id,
          "capabilities" => [%{"resource_uri" => "arbor://fs/write/reports/x"}],
          "signature" => ""
        })
      )

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.SignCaps.run([
                 "--key-file",
                 Path.join(tmp_dir, "nonexistent.arbor.key"),
                 "--workdir",
                 tmp_dir,
                 "--args-json",
                 "{}",
                 caps_path
               ])
             ) == {:shutdown, 1}
    end
  end

  describe "arbor.scheduler.audit_caps" do
    test "reports ok/missing/error across a pipelines dir", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      # Set up a pipelines dir containing three .dot files in different states:
      #   ok.dot         — has a signed valid .caps.json
      #   missing.dot    — no .caps.json (operator forgot)
      #   broken.dot     — has a .caps.json signed by an unenrolled issuer
      pipelines_dir = Path.join(tmp_dir, "pipelines")
      File.mkdir_p!(pipelines_dir)

      File.write!(Path.join(pipelines_dir, "ok.dot"), "digraph X { start [shape=Mdiamond] }")
      File.write!(Path.join(pipelines_dir, "missing.dot"), "digraph X { start [shape=Mdiamond] }")
      File.write!(Path.join(pipelines_dir, "broken.dot"), "digraph X { start [shape=Mdiamond] }")

      # Enroll the issuer so ok.caps.json loads cleanly.
      {:ok, envelope} =
        Capability.new(resource_uri: @envelope_uri, principal_id: identity.agent_id)

      :ok = Security.register_issuer_fixture(identity.agent_id, envelope, reason: "audit test")

      write_signed_caps(
        Path.join(pipelines_dir, "ok.caps.json"),
        identity,
        [%{resource_uri: "arbor://fs/write/reports/ok/**", constraints: %{}}],
        tmp_dir
      )

      # broken.caps.json: signed by a DIFFERENT identity that is NOT enrolled
      {:ok, other_identity} = Identity.generate()
      :ok = Security.register_identity_fixture(other_identity)

      write_signed_caps(
        Path.join(pipelines_dir, "broken.caps.json"),
        other_identity,
        [%{resource_uri: "arbor://fs/write/reports/broken/**", constraints: %{}}],
        tmp_dir
      )

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.AuditCaps.run([
                 "--pipelines-dir",
                 pipelines_dir,
                 "--local"
               ])
             ) == {:shutdown, 1}

      # Drain shell messages and check we got the expected status lines.
      messages = drain_shell_messages()

      assert Enum.any?(messages, &(&1 =~ "ok" and &1 =~ "ok ("))
      assert Enum.any?(messages, &(&1 =~ "missing"))
      assert Enum.any?(messages, &(&1 =~ "broken" and &1 =~ "issuer_not_found"))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_key_file(path, identity) do
    File.write!(path, """
    agent_id=#{identity.agent_id}
    private_key_b64=#{Base.encode64(identity.private_key)}
    """)

    # sign_caps refuses a group/world-readable private key
    # ({:insecure_permissions, 420} == 0o644). File.write!/2 honours the
    # developer's umask, so without this the fixture is 0644 on a default macOS
    # umask and every sign_caps test aborts on permissions — including the
    # issuer_mismatch regression, which then never reaches its own assertion.
    # Write the mode the production contract requires instead of inheriting it.
    File.chmod!(path, 0o600)
  end

  defp write_signed_caps(path, identity, caps, root) do
    dot_path = String.replace_suffix(path, ".caps.json", ".dot")
    {:ok, workdir} = PipelinePaths.resolve_workdir(root)

    {:ok, payload} =
      CapsFile.build(identity.agent_id, caps,
        pipeline_root: "test",
        pipeline_path: Path.relative_to(dot_path, root),
        graph_hash: sha256(File.read!(dot_path)),
        workdir: workdir,
        initial_args: %{}
      )

    signature =
      Security.sign_ed25519_fixture(CapsFile.signing_payload(payload), identity.private_key)

    File.write!(path, payload |> CapsFile.manifest_map(signature) |> Jason.encode!())
  end

  defp drain_shell_messages do
    drain_shell_messages([])
  end

  defp drain_shell_messages(acc) do
    receive do
      {:mix_shell, :info, [msg]} -> drain_shell_messages([msg | acc])
      {:mix_shell, :error, [msg]} -> drain_shell_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp restore_env(key) do
    previous = Application.get_env(:arbor_scheduler, key, :__missing__)

    on_exit(fn ->
      case previous do
        :__missing__ -> Application.delete_env(:arbor_scheduler, key)
        value -> Application.put_env(:arbor_scheduler, key, value)
      end
    end)
  end
end
