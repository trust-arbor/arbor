defmodule Arbor.Client.KeyFileSecurityRegressionTest do
  use ExUnit.Case, async: true

  test "security regression: public signer refuses group or world readable private key files" do
    root =
      Path.join(System.tmp_dir!(), "arbor-key-permissions-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "operator.key")
    {_pub, key} = :crypto.generate_key(:eddsa, :ed25519)

    File.write!(
      path,
      "agent_id=agent_permission_regression\nprivate_key_b64=#{Base.encode64(key)}\n"
    )

    for mode <- [0o640, 0o604, 0o644] do
      File.chmod!(path, mode)
      result = Arbor.Client.Signer.load_key(path)
      # Keep the assertion diagnostic free of key material on the old version.
      refused =
        case result do
          {:error, {:insecure_permissions, ^mode}} -> true
          _ -> false
        end

      assert refused == true
    end
  end
end
