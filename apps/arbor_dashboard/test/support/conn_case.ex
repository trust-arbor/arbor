defmodule Arbor.Dashboard.ConnCase do
  @moduledoc """
  Test case template for LiveView tests in the Arbor Dashboard.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Arbor.Dashboard.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
