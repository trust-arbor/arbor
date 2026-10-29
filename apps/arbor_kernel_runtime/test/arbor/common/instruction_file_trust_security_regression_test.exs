defmodule Arbor.Common.InstructionFileTrustSecurityRegressionTest do
  @moduledoc """
  Security regression: instruction and context files (AGENTS.md, CLAUDE.md,
  SKILL.md) must not be admitted as trusted instructions from an unapproved
  folder or a symlink that escapes the approved set.

  Approved folders are configured trusted roots plus the agent's own config
  dir. Paths are classified after symlink resolution with segment-safe
  containment, so `/tmp/approved-evil` is not treated as inside `/tmp/approved`.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.Config.Testing
  alias Arbor.Common.ProjectContext
  alias Arbor.Common.SkillLibrary

  setup do
    Testing.isolate_namespace()
    stop_skill_library()

    on_exit(fn -> stop_skill_library() end)

    :ok
  end

  test "security regression: unapproved or symlink-escaped instruction files are not trusted" do
    approved = scratch_dir!("instr-approved")
    unapproved = scratch_dir!("instr-unapproved")
    outside = scratch_dir!("instr-outside")
    agent_dir = scratch_dir!("instr-agent")
    prefix_twin = approved <> "-evil"

    File.mkdir_p!(Path.join(approved, ".git"))
    File.mkdir_p!(Path.join(unapproved, ".git"))
    File.mkdir_p!(prefix_twin)
    File.mkdir_p!(Path.join(prefix_twin, ".git"))

    File.write!(Path.join(approved, "AGENTS.md"), "APPROVED_ROOT_RULES")
    File.write!(Path.join(agent_dir, "AGENTS.md"), "APPROVED_AGENT_RULES")
    File.write!(Path.join(unapproved, "AGENTS.md"), "UNAPPROVED_INJECT")
    File.write!(Path.join(prefix_twin, "AGENTS.md"), "PREFIX_TWIN_INJECT")
    File.write!(Path.join(outside, "AGENTS.md"), "SYMLINK_OUT_INJECT")

    escaped = Path.join(approved, "escaped")
    File.mkdir_p!(escaped)
    File.ln_s!(Path.join(outside, "AGENTS.md"), Path.join(escaped, "AGENTS.md"))

    opts = [
      globals: [Path.join(agent_dir, "AGENTS.md")],
      trusted_roots: [approved],
      agent_config_dir: agent_dir
    ]

    approved_out = ProjectContext.load(approved, opts)
    assert approved_out =~ "APPROVED_ROOT_RULES"
    assert approved_out =~ "APPROVED_AGENT_RULES"
    assert trusted_context?(approved_out, Path.join(approved, "AGENTS.md"))

    unapproved_out = ProjectContext.load(unapproved, opts)
    refute unapproved_out =~ "UNAPPROVED_INJECT"
    refute trusted_context?(unapproved_out, Path.join(unapproved, "AGENTS.md"))
    assert unapproved_out =~ "APPROVED_AGENT_RULES"

    escaped_out = ProjectContext.load(escaped, opts)
    refute escaped_out =~ "SYMLINK_OUT_INJECT"
    refute trusted_context?(escaped_out, Path.join(escaped, "AGENTS.md"))
    refute trusted_context?(escaped_out, Path.join(outside, "AGENTS.md"))

    prefix_out = ProjectContext.load(prefix_twin, opts)
    refute prefix_out =~ "PREFIX_TWIN_INJECT"
    refute trusted_context?(prefix_out, Path.join(prefix_twin, "AGENTS.md"))
  end

  test "security regression: unapproved or symlink-escaped skills are not trusted" do
    approved = scratch_dir!("skill-approved")
    unapproved = scratch_dir!("skill-unapproved")
    outside = scratch_dir!("skill-outside")

    Testing.put(:instruction_trusted_roots, [approved])

    write_skill(Path.join([approved, "approved-skill", "SKILL.md"]), "approved-skill", "GOOD")
    write_skill(Path.join([unapproved, "unapproved-skill", "SKILL.md"]), "unapproved-skill", "BAD")
    write_skill(Path.join([outside, "linked-skill", "SKILL.md"]), "linked-skill", "LINK")
    File.ln_s!(Path.join(outside, "linked-skill"), Path.join(approved, "linked-skill"))

    assert {:ok, _pid} = SkillLibrary.start_link(dirs: [])
    assert {:ok, 1} = SkillLibrary.index(approved)
    assert {:ok, 1} = SkillLibrary.index(unapproved)

    assert {:ok, approved_skill} = SkillLibrary.get("approved-skill")
    assert approved_skill.taint == :trusted
    assert approved_skill.body =~ "GOOD"

    assert {:ok, unapproved_skill} = SkillLibrary.get("unapproved-skill")
    assert unapproved_skill.taint == :untrusted
    refute unapproved_skill.taint == :trusted

    assert {:error, :not_found} = SkillLibrary.get("linked-skill")
  end

  defp trusted_context?(output, path) do
    output =~ "--- Context from: #{path} ---"
  end

  defp write_skill(path, name, body) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    name: #{name}
    description: Instruction trust security regression fixture
    ---

    #{body}
    """)
  end

  defp scratch_dir!(prefix) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "#{prefix}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp stop_skill_library do
    if pid = Process.whereis(SkillLibrary) do
      GenServer.stop(pid)
    end

    if :ets.whereis(:arbor_skill_library) != :undefined do
      :ets.delete(:arbor_skill_library)
    end
  end
end
