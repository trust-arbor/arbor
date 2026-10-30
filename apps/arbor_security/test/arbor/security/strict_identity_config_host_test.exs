defmodule Arbor.Security.StrictIdentityConfigHostTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  test "security regression: development config does not allow arbitrary OIDC subjects" do
    dev_config =
      Path.expand("../../../../../config/dev.exs", __DIR__)
      |> File.read!()

    refute dev_config =~ "oidc_registration_mode: :allow"
  end
end
