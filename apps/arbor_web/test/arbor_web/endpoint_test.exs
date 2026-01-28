defmodule Arbor.Web.EndpointTest do
  use ExUnit.Case, async: true

  describe "Arbor.Web.Endpoint" do
    test "module is defined" do
      assert Code.ensure_loaded?(Arbor.Web.Endpoint)
    end

    test "defines __using__ macro" do
      macros = Arbor.Web.Endpoint.__info__(:macros)
      assert {:__using__, 1} in macros
    end

    test "endpoint macro requires otp_app option" do
      assert_raise KeyError, ~r/key :otp_app not found/, fn ->
        Code.eval_string("""
        defmodule TestEndpointNoOtp do
          use Arbor.Web.Endpoint, []
        end
        """)
      end
    end
  end
end
