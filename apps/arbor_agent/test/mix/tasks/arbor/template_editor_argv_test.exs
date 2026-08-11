defmodule Mix.Tasks.Arbor.TemplateEditorArgvTest do
  @moduledoc """
  Focused tests for template editor executable resolution and inert argv.
  Does not launch a real interactive editor.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Mix.Tasks.Arbor.Template

  setup do
    tmp = Path.join(System.tmp_dir!(), "template_editor_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  test "accepts an absolute executable path that contains spaces", %{tmp: tmp} do
    dir = Path.join(tmp, "My Editors")
    File.mkdir_p!(dir)
    exe = Path.join(dir, "fake editor")
    File.write!(exe, "#!/bin/sh\nexit 0\n")
    File.chmod!(exe, 0o755)

    assert {:ok, resolved} = Template.resolve_editor_executable(exe)
    assert File.regular?(resolved)
    assert Path.basename(resolved) == "fake editor"

    template_path = Path.join(tmp, "scout.json")
    assert {:ok, ^resolved, [^template_path]} = Template.editor_argv(exe, template_path)
  end

  test "accepts a bare command name on PATH" do
    case System.find_executable("true") || System.find_executable("sh") do
      nil ->
        flunk("need true or sh on PATH for bare-name resolution test")

      found ->
        name = Path.basename(found)
        assert {:ok, resolved} = Template.resolve_editor_executable(name)
        assert File.regular?(resolved)
        assert {:ok, ^resolved, ["/tmp/t.json"]} = Template.editor_argv(name, "/tmp/t.json")
    end
  end

  test "rejects unresolved bare name" do
    name = "definitely_not_an_editor_#{System.unique_integer([:positive])}"
    assert {:error, :unresolved_editor} = Template.resolve_editor_executable(name)
  end

  test "rejects compound editor values that require command parsing" do
    assert {:error, :compound_editor} = Template.resolve_editor_executable("vim -n")
    assert {:error, :compound_editor} = Template.resolve_editor_executable("code --wait")
    assert {:error, :compound_editor} = Template.resolve_editor_executable("$(touch pwned)")
    assert {:error, :compound_editor} = Template.resolve_editor_executable("emacs; id")
  end

  test "rejects empty editor" do
    assert {:error, :empty_editor} = Template.resolve_editor_executable("   ")
  end

  test "template path with spaces remains one inert argv element", %{tmp: tmp} do
    exe = Path.join(tmp, "ed")
    File.write!(exe, "#!/bin/sh\nexit 0\n")
    File.chmod!(exe, 0o755)

    template_path = Path.join(tmp, "my template.json")
    assert {:ok, _exe, [^template_path]} = Template.editor_argv(exe, template_path)
  end

  test "absolute non-executable path with spaces is not accepted as compound-ok", %{tmp: tmp} do
    path = Path.join(tmp, "not an editor.txt")
    File.write!(path, "nope\n")
    assert {:error, :compound_editor} = Template.resolve_editor_executable(path)
  end
end
