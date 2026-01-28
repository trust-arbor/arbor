defmodule Arbor.Web.RouterTest do
  use ExUnit.Case, async: true

  alias Arbor.Web.Router

  describe "Arbor.Web.Router" do
    test "module is defined" do
      assert Code.ensure_loaded?(Router)
    end

    test "defines __using__ macro" do
      macros = Router.__info__(:macros)
      assert {:__using__, 1} in macros
    end

    test "defines arbor_browser_pipeline macros" do
      macros = Router.__info__(:macros)
      assert {:arbor_browser_pipeline, 0} in macros
      assert {:arbor_browser_pipeline, 1} in macros
    end
  end
end
