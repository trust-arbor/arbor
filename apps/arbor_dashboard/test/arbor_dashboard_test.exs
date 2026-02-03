defmodule Arbor.DashboardTest do
  use ExUnit.Case

  describe "module structure" do
    test "Arbor.Dashboard module exists" do
      assert Code.ensure_loaded?(Arbor.Dashboard)
    end

    test "Application module exists" do
      assert Code.ensure_loaded?(Arbor.Dashboard.Application)
    end

    test "Endpoint module exists" do
      assert Code.ensure_loaded?(Arbor.Dashboard.Endpoint)
    end

    test "Router module exists" do
      assert Code.ensure_loaded?(Arbor.Dashboard.Router)
    end
  end

  describe "LiveViews" do
    test "LandingLive module exists" do
      assert Code.ensure_loaded?(Arbor.Dashboard.Live.LandingLive)
    end

    test "SignalsLive module exists" do
      assert Code.ensure_loaded?(Arbor.Dashboard.Live.SignalsLive)
    end

    test "EvalLive module exists" do
      assert Code.ensure_loaded?(Arbor.Dashboard.Live.EvalLive)
    end
  end

  describe "Nav on_mount" do
    test "Nav module exports on_mount/4" do
      Code.ensure_loaded!(Arbor.Dashboard.Nav)
      assert function_exported?(Arbor.Dashboard.Nav, :on_mount, 4)
    end
  end
end
