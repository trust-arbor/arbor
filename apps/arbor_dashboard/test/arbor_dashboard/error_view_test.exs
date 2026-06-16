defmodule Arbor.Dashboard.ErrorViewTest do
  # Regression for the CI-only ConsensusLive 500s. The dashboard endpoint had no
  # render_errors view configured, so Phoenix derived the default
  # `Arbor.ErrorView` — a module that does not exist. Any request that raised
  # (e.g. a mid-mount 503 from OidcAuth) then crashed the render-errors path
  # itself with `no "500" html template defined for Arbor.ErrorView`, MASKING
  # the original exception. These tests pin a real, rendering error view so the
  # render-errors path can never crash that way again.
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Dashboard.{ErrorHTML, ErrorJSON}

  describe "error views render status messages" do
    test "ErrorHTML renders the HTTP status message for a template" do
      assert ErrorHTML.render("404.html", %{}) == "Not Found"
      assert ErrorHTML.render("500.html", %{}) == "Internal Server Error"
      assert ErrorHTML.render("503.html", %{}) == "Service Unavailable"
    end

    test "ErrorJSON renders the HTTP status message under errors.detail" do
      assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
      assert ErrorJSON.render("500.json", %{}) == %{errors: %{detail: "Internal Server Error"}}
    end
  end

  describe "endpoint render_errors configuration" do
    test "regression: configured error views exist and are loadable" do
      # Without an explicit render_errors config, Phoenix derives the view from
      # the endpoint's top namespace -> Arbor.ErrorView, which does NOT exist.
      # Assert the configured formats point at modules that actually load, so a
      # future config drift back to a phantom module is caught here, not in CI.
      config = Application.get_env(:arbor_dashboard, Arbor.Dashboard.Endpoint, [])
      render_errors = Keyword.get(config, :render_errors, [])
      formats = Keyword.get(render_errors, :formats, [])

      assert formats != [],
             "Arbor.Dashboard.Endpoint must configure render_errors :formats explicitly — " <>
               "otherwise Phoenix derives the nonexistent Arbor.ErrorView and the " <>
               "render-errors path crashes, masking the real exception."

      for {_format, module} <- formats do
        assert Code.ensure_loaded?(module),
               "render_errors view #{inspect(module)} does not exist — " <>
                 "this is the Arbor.ErrorView gap that masked the ConsensusLive 500s."
      end
    end
  end
end
