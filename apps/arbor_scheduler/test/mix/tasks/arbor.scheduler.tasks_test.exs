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
  alias Arbor.Scheduler.CapsFile
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  @envelope_uri "arbor://fs/write/reports/**"

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, identity} = Identity.generate()
    :ok = IdentityRegistry.register(identity)

    tmp = System.tmp_dir!() |> Path.join("scheduler_tasks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      IssuerRegistry.revoke(identity.agent_id, "test cleanup")
      File.rm_rf!(tmp)
    end)

    {:ok, identity: identity, tmp_dir: tmp}
  end

  describe "arbor.scheduler.enroll_issuer" do
    test "enrolls an identity with envelope URI", %{identity: identity} do
      Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
        "--issuer-id",
        identity.agent_id,
        "--envelope-uri",
        @envelope_uri,
        "--reason",
        "test enrollment"
      ])

      assert_received {:mix_shell, :info, [msg]}
      assert msg == "Enrolled issuer:"

      entries = IssuerRegistry.list()
      entry = Enum.find(entries, &(&1.issuer_id == identity.agent_id))
      assert entry.max_envelope_cap.resource_uri == @envelope_uri
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

    test "fails for unregistered identity" do
      bogus_id = "agent_9999999999999999999999999999999999999999999999999999999999999999"

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.EnrollIssuer.run([
                 "--issuer-id",
                 bogus_id,
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
      key_path = Path.join(tmp_dir, "test.arbor.key")

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

      :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "sign_caps test")

      Mix.Tasks.Arbor.Scheduler.SignCaps.run([
        "--key-file",
        key_path,
        caps_path
      ])

      assert {:ok, [%{resource_uri: uri}]} = CapsFile.load(caps_path)
      assert uri == "arbor://fs/write/reports/upstream-deps-summary/**"
    end

    test "regression: refuses to sign when key's agent_id doesn't match caps file issuer_id",
         %{identity: identity, tmp_dir: tmp_dir} do
      # The sign step verifies the operator isn't signing under the wrong
      # identity. Without this check, a stolen key could produce a signed
      # file ostensibly from someone else (the signature would still fail
      # at load time, but earlier failure with a clear error helps ops).
      caps_path = Path.join(tmp_dir, "mismatched.caps.json")
      key_path = Path.join(tmp_dir, "other.arbor.key")

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
                 caps_path
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "issuer_mismatch"
    end

    test "fails for missing key file", %{identity: identity, tmp_dir: tmp_dir} do
      caps_path = Path.join(tmp_dir, "any.caps.json")

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

      :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "audit test")

      write_signed_caps(
        Path.join(pipelines_dir, "ok.caps.json"),
        identity,
        [%{resource_uri: "arbor://fs/write/reports/ok/**", constraints: %{}}]
      )

      # broken.caps.json: signed by a DIFFERENT identity that is NOT enrolled
      {:ok, other_identity} = Identity.generate()
      :ok = IdentityRegistry.register(other_identity)

      write_signed_caps(
        Path.join(pipelines_dir, "broken.caps.json"),
        other_identity,
        [%{resource_uri: "arbor://fs/write/reports/broken/**", constraints: %{}}]
      )

      assert catch_exit(
               Mix.Tasks.Arbor.Scheduler.AuditCaps.run([
                 "--pipelines-dir",
                 pipelines_dir
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
  end

  defp write_signed_caps(path, identity, caps) do
    parsed = CapsFile.build(identity.agent_id, caps)
    payload = CapsFile.signing_payload(parsed)
    sig = Arbor.Security.Crypto.sign(payload, identity.private_key)

    json = %{
      "version" => parsed.version,
      "issuer_id" => parsed.issuer_id,
      "capabilities" =>
        Enum.map(parsed.capabilities, fn c ->
          %{"resource_uri" => c.resource_uri, "constraints" => c.constraints}
        end),
      "signature" => Base.encode64(sig)
    }

    File.write!(path, Jason.encode!(json))
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
end
