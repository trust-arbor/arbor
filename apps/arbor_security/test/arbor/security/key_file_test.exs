defmodule Arbor.Security.KeyFileTest do
  @moduledoc """
  Tests for `Arbor.Security.KeyFile`. The bulk of the parse/1 semantics
  are exercised through `Arbor.Gateway.Signer.ProxyCore.parse_key_file/1`
  (which delegates here); these tests cover the `read/1` convenience
  layer specifically.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Security.KeyFile

  setup do
    tmp = System.tmp_dir!() |> Path.join("key_file_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  describe "read/1" do
    test "reads and parses a well-formed key file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ok.arbor.key")

      File.write!(path, """
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
      File.write!(path, "agent_id=agent_abc\n")

      assert {:error, {:missing_field, "private_key_b64"}} = KeyFile.read(path)
    end
  end
end
