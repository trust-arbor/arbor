defmodule Arbor.Contracts.Security.IdentityInspectSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity

  # 2026-10-11 cross-library review F-022: Identity carried raw private key
  # bytes with no Inspect redaction, so any `inspect/1` in a log line or crash
  # report printed signing material.
  test "security regression (F-022): inspect/1 never prints private key material" do
    identity = %Identity{
      agent_id: "agent_inspect_regression",
      public_key: "PUBLIC_KEY_BYTES",
      private_key: "SECRET_SIGNING_KEY_BYTES_DO_NOT_LEAK",
      encryption_public_key: "ENC_PUBLIC",
      encryption_private_key: "SECRET_ENCRYPTION_KEY_BYTES_DO_NOT_LEAK",
      created_at: DateTime.utc_now()
    }

    rendered = inspect(identity)

    refute rendered =~ "SECRET_SIGNING_KEY_BYTES_DO_NOT_LEAK"
    refute rendered =~ "SECRET_ENCRYPTION_KEY_BYTES_DO_NOT_LEAK"
    refute rendered =~ "private_key"
    assert rendered =~ "agent_inspect_regression"
    assert rendered =~ "PUBLIC_KEY_BYTES"
  end
end
