defmodule Arbor.Shell.SandboxCapCheckTest do
  @moduledoc """
  Security regression tests for the capability-derived shell sandbox allowlist
  (Arbor.Shell.Sandbox.check/3 with an :allowlist opt).

  Invariants:
  - the cap-derived allowlist REPLACES the hardcoded level allowlist for the
    command check (fixes "granted git, still blocked by :strict");
  - the safety floor (metacharacters, dangerous-command/interpreter/flag
    blocking) is ALWAYS applied — a capability grant lets an agent run a command
    but never escape it or override the floor;
  - system callers (no :allowlist opt) keep the unchanged level behavior.
  """
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Shell.Sandbox

  @git_only [allowlist: {:commands, MapSet.new(["git"])}]
  @wildcard [allowlist: :all]
  @empty [allowlist: {:commands, MapSet.new()}]

  describe "cap-derived allowlist — friction fix" do
    test "a granted command runs even though the level allowlist would block it" do
      # `git` is NOT in the hardcoded :strict @strict_allowlist — pre-cap-derived
      # this returned {:error, {:not_in_allowlist, "git"}} despite the grant.
      assert {:ok, :allowed} = Sandbox.check("git status", :strict, @git_only)
      assert {:ok, :allowed} = Sandbox.check("git status", :basic, @git_only)
    end

    test "a wildcard (:all) allowlist permits arbitrary non-floored commands" do
      assert {:ok, :allowed} = Sandbox.check("whoami", :strict, @wildcard)
      assert {:ok, :allowed} = Sandbox.check("git log", :strict, @wildcard)
    end
  end

  describe "cap-derived allowlist — safety floor still applies" do
    test "metacharacter escape to an ungranted command is blocked" do
      # The agent holds only `git`. Chaining to `rm` via `;` must be blocked even
      # though `git` is granted — otherwise the grant becomes arbitrary exec.
      assert {:error, _} = Sandbox.check("git status; rm -rf /", :strict, @git_only)
      assert {:error, _} = Sandbox.check("git status && rm -rf /", :strict, @git_only)
      assert {:error, _} = Sandbox.check("git $(rm -rf /)", :strict, @git_only)
    end

    test "a granted dangerous command is still blocked by the floor" do
      # Granting `arbor://shell/exec/rm` does NOT override the dangerous-command
      # floor (the floor is the absolute denylist).
      assert {:error, {:blocked_command, "rm"}} =
               Sandbox.check("rm -rf /", :strict, allowlist: {:commands, MapSet.new(["rm"])})

      # Even a wildcard grant does not lift the floor.
      assert {:error, {:blocked_command, _}} = Sandbox.check("rm -rf /", :basic, @wildcard)
    end

    test "a granted interpreter is still blocked by the floor" do
      assert {:error, {:blocked_interpreter, _}} =
               Sandbox.check("sh -c 'rm -rf /'", :strict, allowlist: {:commands, MapSet.new(["sh"])})

      assert {:error, {:blocked_interpreter, _}} = Sandbox.check("bash -c ls", :basic, @wildcard)
    end

    test "dangerous flags are still blocked even for a granted command" do
      # `git` is granted, but `--force` is in the dangerous-flag floor.
      assert {:error, {:dangerous_flags, _}} = Sandbox.check("git push --force", :strict, @git_only)
    end
  end

  describe "cap-derived allowlist — deny" do
    test "an ungranted command is denied" do
      assert {:error, {:not_in_allowlist, "ls"}} = Sandbox.check("ls -la", :strict, @git_only)
    end

    test "an empty allowlist denies everything" do
      assert {:error, {:not_in_allowlist, _}} = Sandbox.check("git status", :strict, @empty)
    end

    test ":none bypasses the sandbox even with an allowlist (capability gate already authorized)" do
      assert {:ok, :allowed} = Sandbox.check("anything goes", :none, @git_only)
    end
  end

  describe "system callers (no :allowlist) — unchanged level behavior" do
    test ":strict still enforces only the hardcoded allowlist" do
      assert {:ok, :allowed} = Sandbox.check("ls -la", :strict)
      assert {:error, {:not_in_allowlist, "git"}} = Sandbox.check("git status", :strict)
    end

    test ":basic still blocks dangerous commands and allows the rest" do
      assert {:ok, :allowed} = Sandbox.check("git status", :basic)
      assert {:error, {:blocked_command, "rm"}} = Sandbox.check("rm -rf /", :basic)
    end

    test ":none allows anything" do
      assert {:ok, :allowed} = Sandbox.check("rm -rf /", :none)
    end
  end
end
