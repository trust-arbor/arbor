defmodule Arbor.Security.KeyFileTest do
  @moduledoc """
  Tests for `Arbor.Security.KeyFile`. The bulk of the parse/1 semantics
  are exercised through `Arbor.Gateway.Signer.ProxyCore.parse_key_file/1`
  (which delegates here); these tests cover read/write, the principal-prefix
  allowlist, and fail-closed permission checks.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  import Bitwise

  alias Arbor.Security
  alias Arbor.Security.{Crypto, KeyFile}

  setup do
    tmp = System.tmp_dir!() |> Path.join("key_file_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  defp write_private!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  describe "parse/1 principal allowlist" do
    test "accepts agent_ principal ids" do
      contents = """
      agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """

      assert {:ok, %{agent_id: id}} = KeyFile.parse(contents)
      assert String.starts_with?(id, "agent_")
    end

    test "accepts human_ principal ids minted by mix arbor.user.init" do
      contents = """
      agent_id=human_0123456789abcdef0123456789abcdef01234567
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """

      assert {:ok, %{agent_id: "human_0123456789abcdef0123456789abcdef01234567"}} =
               KeyFile.parse(contents)
    end

    test "rejects prefixes outside the agent_/human_ allowlist" do
      contents = """
      agent_id=system_authority
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """

      assert {:error, {:invalid_agent_id, "system_authority"}} = KeyFile.parse(contents)
    end

    test "rejects a prefix with no identifier remainder" do
      contents = """
      agent_id=human_
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """

      assert {:error, {:invalid_agent_id, "human_"}} = KeyFile.parse(contents)
    end

    test "security regression: the public operator parser rejects oversized contents" do
      assert {:error, :invalid_key_file_size} =
               Security.parse_operator_key_file_contents(:binary.copy(<<"x">>, 4_097))
    end
  end

  describe "sign_scheduler_caps_payload/2" do
    test "security regression: returns a bounded error for unsupported key material", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "unsupported-scheduler.arbor.key")
      principal_id = "agent_" <> String.duplicate("a", 64)
      material = %{agent_id: principal_id, private_key: :binary.copy(<<42>>, 64)}

      # Historical 64-byte material passes KeyFile validation, but OTP's
      # Ed25519 signer rejects it. Do not truncate it into a different key.
      assert {:ok, _path} = Security.write_key_file(path, material)
      domain = "arbor.scheduler.caps.v2"
      payload = <<byte_size(domain)::32-big, domain::binary, "canonical-caps-body">>
      {:ok, io_device} = :file.open(path, [:read, :raw, :binary])

      try do
        result =
          try do
            Security.sign_scheduler_caps_payload(io_device, payload)
          rescue
            _ -> :unhandled_signing_exception
          end

        assert {:error, :invalid_key_file_signing_material} = result
      after
        :file.close(io_device)
      end
    end

    test "security regression: signs only the exact canonical scheduler domain", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "scheduler.arbor.key")
      {public_key, private_key} = Crypto.generate_keypair()
      principal_id = "agent_" <> String.duplicate("a", 64)

      write_private!(path, """
      agent_id=#{principal_id}
      private_key_b64=#{Base.encode64(private_key)}
      """)

      domain = "arbor.scheduler.caps.v2"
      payload = <<byte_size(domain)::32-big, domain::binary, "canonical-caps-body">>
      wrong_domain = "arbor.scheduler.caps.v1"
      wrong_payload = <<byte_size(wrong_domain)::32-big, wrong_domain::binary, "body">>

      {:ok, io_device} = :file.open(String.to_charlist(path), [:read, :raw, :binary])

      try do
        assert {:error, :invalid_scheduler_caps_payload} =
                 Security.sign_scheduler_caps_payload(io_device, wrong_payload)

        assert {:ok, ^principal_id, signature} =
                 Security.sign_scheduler_caps_payload(io_device, payload)

        assert :ok = Security.verify_detached(payload, signature, public_key)

        assert {:error, :invalid_signature} =
                 Security.verify_detached(payload <> "tampered", signature, public_key)
      after
        :file.close(io_device)
      end
    end
  end

  describe "serialize/1" do
    test "round-trips through parse/1" do
      material = %{
        agent_id: "human_0123456789abcdef0123456789abcdef01234567",
        private_key: :crypto.strong_rand_bytes(32)
      }

      assert {:ok, contents} = KeyFile.serialize(material)
      refute String.contains?(contents, material.private_key)
      assert {:ok, ^material} = KeyFile.parse(contents)
    end

    test "rejects material outside the principal allowlist" do
      assert {:error, {:invalid_agent_id, "system_authority"}} =
               KeyFile.serialize(%{
                 agent_id: "system_authority",
                 private_key: :crypto.strong_rand_bytes(32)
               })
    end
  end

  describe "read/1" do
    test "reads and parses a well-formed key file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ok.arbor.key")

      write_private!(path, """
      agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """)

      assert {:ok, %{agent_id: id, private_key: pk}} = KeyFile.read(path)
      assert String.starts_with?(id, "agent_")
      assert byte_size(pk) == 32
    end

    test "returns {:read_failed, :enoent} for missing file", %{tmp_dir: tmp_dir} do
      assert {:error, {:read_failed, :enoent}} =
               KeyFile.read(Path.join(tmp_dir, "nope.arbor.key"))
    end

    test "propagates parse errors", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing_field.arbor.key")
      write_private!(path, "agent_id=agent_abc\n")

      assert {:error, {:missing_field, "private_key_b64"}} = KeyFile.read(path)
    end

    test "fails closed when group or other can read the file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "world.arbor.key")

      File.write!(path, """
      agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """)

      File.chmod!(path, 0o644)

      assert {:error, {:insecure_permissions, 0o644}} = KeyFile.read(path)
    end
  end

  describe "write/2" do
    test "creates a 0600 file and refuses to clobber it", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "operator.key")

      material = %{
        agent_id: "human_0123456789abcdef0123456789abcdef01234567",
        private_key: :crypto.strong_rand_bytes(32)
      }

      assert {:ok, written} = KeyFile.write(path, material)
      assert written == Path.expand(path)
      assert File.exists?(written)

      stat = File.stat!(written)
      assert band(stat.mode, 0o777) == 0o600

      assert {:ok, ^material} = KeyFile.read(written)

      original = File.read!(written)

      assert {:error, :already_exists} = KeyFile.write(path, material)
      assert File.read!(written) == original
    end

    test "does not create a file when serialization fails", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid.key")

      assert {:error, {:invalid_agent_id, "not_a_principal"}} =
               KeyFile.write(path, %{
                 agent_id: "not_a_principal",
                 private_key: :crypto.strong_rand_bytes(32)
               })

      refute File.exists?(path)
    end
  end
end
