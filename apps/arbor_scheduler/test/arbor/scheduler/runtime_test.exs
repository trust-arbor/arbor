defmodule Arbor.Scheduler.RuntimeTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Scheduler.Runtime

  test "standby Oban keeps the configured instance but runs no queues or plugins" do
    %{id: standby_id, start: {Oban, :start_link, [standby_opts]}} =
      Runtime.oban_child_spec(:standby)

    %{id: active_id, start: {Oban, :start_link, [active_opts]}} =
      Runtime.oban_child_spec(:active)

    assert standby_id == active_id
    assert Keyword.fetch!(standby_opts, :name) == Keyword.fetch!(active_opts, :name)
    assert Keyword.fetch!(standby_opts, :repo) == Keyword.fetch!(active_opts, :repo)
    assert Keyword.fetch!(standby_opts, :queues) == false
    assert Keyword.fetch!(standby_opts, :plugins) == false
  end
end
