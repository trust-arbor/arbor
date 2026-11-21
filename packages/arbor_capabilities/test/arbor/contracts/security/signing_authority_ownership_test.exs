defmodule Arbor.Contracts.Security.SigningAuthorityOwnershipTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "Capabilities is the sole loaded owner of shared signing-authority modules" do
    assert :ok = ensure_loaded(:arbor_capabilities)

    modules = [
      Arbor.Contracts.Security.SigningAuthority,
      Arbor.Contracts.Security.SigningAuthorityBootstrap,
      Arbor.Contracts.Security.SigningAuthority.Validator
    ]

    for module <- modules do
      owners =
        for {app, _description, _version} <- Application.loaded_applications(),
            module in (Application.spec(app, :modules) || []),
            do: app

      assert owners == [:arbor_capabilities],
             "unexpected owners for #{inspect(module)}: #{inspect(owners)}"

      assert Application.get_application(module) == :arbor_capabilities
    end
  end

  defp ensure_loaded(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
    end
  end
end
