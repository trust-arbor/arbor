defmodule Mix.Tasks.Arbor.SetupTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Setup

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "arbor_setup_#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(tmp)
    {:ok, tmp} = SafePath.resolve_real(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  test "fetch_deps uses the absolute reviewed wrapper with exact argv in a fresh process", %{
    tmp: tmp
  } do
    bin_dir = Path.join(tmp, "bin")
    wrapper = Path.join(bin_dir, "mix")
    invocation = Path.join(tmp, "invocation")
    File.mkdir_p!(bin_dir)

    File.write!(wrapper, """
    #!/bin/sh
    set -eu
    {
      printf 'executable=%s\\n' "$0"
      printf 'argc=%s\\n' "$#"
      printf 'arg1=%s\\n' "$1"
      printf 'cwd=%s\\n' "$(pwd)"
    } > "#{invocation}"
    """)

    File.chmod!(wrapper, 0o755)

    assert {:ok, ^wrapper} = Setup.resolve_mix_wrapper(tmp)
    assert {:ok, "done"} = Setup.fetch_deps(tmp)

    assert File.read!(invocation) ==
             "executable=#{wrapper}\nargc=1\narg1=deps.get\ncwd=#{tmp}\n"
  end

  test "resolve_mix_wrapper fails closed with an actionable error when wrapper is missing", %{
    tmp: tmp
  } do
    expected = Path.join(tmp, "bin/mix")

    assert {:error, message} = Setup.resolve_mix_wrapper(tmp)
    assert message =~ "does not exist at #{expected}"
    assert message =~ "restore bin/mix with executable mode"
  end

  test "resolve_mix_wrapper fails closed when wrapper is not executable", %{tmp: tmp} do
    wrapper = Path.join(tmp, "bin/mix")
    File.mkdir_p!(Path.dirname(wrapper))
    File.write!(wrapper, "#!/bin/sh\nexit 0\n")
    File.chmod!(wrapper, 0o644)

    assert {:error, message} = Setup.resolve_mix_wrapper(tmp)
    assert message =~ "is not executable at #{wrapper}"
    assert message =~ "restore bin/mix with executable mode"
  end
end
