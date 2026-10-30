defmodule Arbor.Security.EscalationConfigHostTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security.Config
  alias Elixir.Config.Reader

  describe "config seam" do
    test "interaction_router defaults to Arbor.Comms.InteractionRouter" do
      previous = Application.fetch_env(:arbor_capabilities, :interaction_router)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_capabilities, :interaction_router, value)
          :error -> Application.delete_env(:arbor_capabilities, :interaction_router)
        end
      end)

      product_config =
        Path.expand("../../../../../config/config.exs", __DIR__)
        |> Reader.read!(env: :test, target: :host)

      router =
        product_config
        |> Keyword.fetch!(:arbor_capabilities)
        |> Keyword.fetch!(:interaction_router)

      Application.put_env(:arbor_capabilities, :interaction_router, router)

      assert Config.interaction_router() ==
               Module.concat(["Arbor", "Comms", "InteractionRouter"])
    end
  end
end
