defmodule Arbor.Web.EndpointTest do
  use ExUnit.Case, async: true

  alias Arbor.Web.Endpoint

  describe "Arbor.Web.Endpoint" do
    test "module is defined" do
      assert Code.ensure_loaded?(Endpoint)
    end

    test "defines __using__ macro" do
      macros = Endpoint.__info__(:macros)
      assert {:__using__, 1} in macros
    end

    test "endpoint macro requires otp_app option" do
      assert_raise KeyError, ~r/key :otp_app not found/, fn ->
        # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
        Code.eval_string("""
        defmodule TestEndpointNoOtp do
          use Arbor.Web.Endpoint, []
        end
        """)
      end
    end
  end
end
