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

    test "only code_reloader is compile-time endpoint configuration" do
      require Endpoint

      expanded =
        quote do
          Endpoint.__using__(otp_app: :arbor_dashboard)
        end
        |> Macro.expand_once(__ENV__)
        |> Macro.to_string()

      assert expanded =~
               "Application.compile_env(:arbor_dashboard, [__MODULE__, :code_reloader], false)"

      refute expanded =~ "Application.compile_env(:arbor_dashboard, __MODULE__)"
    end

    test "umbrella registers the Phoenix code reloader Mix listener" do
      assert Phoenix.CodeReloader in Keyword.fetch!(Arbor.MixProject.project(), :listeners)
    end
  end
end
