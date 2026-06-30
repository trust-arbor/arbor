defmodule Arbor.Shell.CapPolicyTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Shell.CapPolicy

  describe "project/1 — capability URIs -> command allowlist" do
    test "projects specific shell/exec caps to their command names" do
      assert {:commands, set} =
               CapPolicy.project([
                 "arbor://shell/exec/git",
                 "arbor://shell/exec/ls",
                 "arbor://fs/read/foo"
               ])

      assert MapSet.equal?(set, MapSet.new(["git", "ls"]))
    end

    test "subcommand- and wildcard-scoped caps project to the command name" do
      assert {:commands, set} =
               CapPolicy.project([
                 "arbor://shell/exec/git/status",
                 "arbor://shell/exec/git/**",
                 "arbor://shell/exec/docker/ps"
               ])

      # Command-name granularity: git (from both git/status and git/**), docker.
      assert MapSet.equal?(set, MapSet.new(["git", "docker"]))
    end

    test "a bare or subtree-wildcard shell/exec cap projects to :all" do
      assert :all = CapPolicy.project(["arbor://shell/exec"])
      assert :all = CapPolicy.project(["arbor://shell/exec/**"])
      # :all wins regardless of other specific caps present.
      assert :all = CapPolicy.project(["arbor://shell/exec/git", "arbor://shell/exec/**"])
    end

    test "no shell/exec caps -> empty allowlist (deny all)" do
      assert {:commands, set} = CapPolicy.project(["arbor://fs/read/x", "arbor://code/read/self"])
      assert MapSet.size(set) == 0
    end
  end

  describe "allows?/2" do
    test ":all permits any command" do
      assert CapPolicy.allows?(:all, "git")
      assert CapPolicy.allows?(:all, "rm")
    end

    test "{:commands, set} permits only listed commands" do
      al = {:commands, MapSet.new(["git", "ls"])}
      assert CapPolicy.allows?(al, "git")
      refute CapPolicy.allows?(al, "rm")
    end

    test "empty allowlist permits nothing" do
      refute CapPolicy.allows?({:commands, MapSet.new()}, "git")
    end
  end
end
