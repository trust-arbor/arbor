defmodule Mix.Tasks.Arbor.BackupTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  describe "module availability" do
    test "task module is loaded" do
      assert {:module, Mix.Tasks.Arbor.Backup} = Code.ensure_loaded(Mix.Tasks.Arbor.Backup)
    end

    test "backup utility module is available" do
      assert Code.ensure_loaded?(Arbor.Persistence.Backup)
    end
  end

  describe "option parsing" do
    test "parses --skip-cleanup flag" do
      {opts, _, _} = OptionParser.parse(["--skip-cleanup"], switches: [skip_cleanup: :boolean])
      assert opts[:skip_cleanup] == true
    end

    test "handles no arguments" do
      {opts, args, _} = OptionParser.parse([], switches: [skip_cleanup: :boolean])
      assert opts == []
      assert args == []
    end
  end
end
