defmodule Arbor.Persistence.ApplicationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "production maintenance archive configuration starts its Ecto Repo" do
    config = Config.Reader.read!(Path.expand("../../../../../config/prod.exs", __DIR__))
    archive_target = get_in(config, [:arbor_memory, :maintenance_archive_target])

    assert Keyword.get(config[:arbor_persistence], :start_repo) == true
    assert archive_target[:backend] == Arbor.Persistence.EventLog.Ecto
    assert archive_target[:opts] == [repo: Arbor.Persistence.Repo]
  end
end
