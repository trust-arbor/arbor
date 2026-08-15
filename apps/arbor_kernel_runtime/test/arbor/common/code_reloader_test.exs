defmodule Arbor.Common.CodeReloaderTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Common.CodeReloader

  @fixture Arbor.Common.CodeReloaderTestFixture

  test "reloads a loaded module when its code-path BEAM is newer" do
    ebin = temporary_ebin!()
    filename = Path.join(ebin, Atom.to_string(@fixture) <> ".beam")
    old_beam = compile_fixture(:old)
    new_beam = compile_fixture(:new)
    unload_fixture()

    assert :code.add_patha(String.to_charlist(ebin)) == true
    on_exit(fn -> cleanup_fixture(ebin) end)

    File.write!(filename, old_beam)

    assert {:module, @fixture} =
             :code.load_binary(@fixture, String.to_charlist(filename), old_beam)

    assert apply(@fixture, :version, []) == :old
    File.write!(filename, new_beam)

    assert {:reloaded, @fixture} = CodeReloader.reload_module(@fixture, ebin)
    assert apply(@fixture, :version, []) == :new
  end

  test "refuses to load a BEAM outside the expected application ebin" do
    ebin = temporary_ebin!()
    other_ebin = temporary_ebin!()
    filename = Path.join(ebin, Atom.to_string(@fixture) <> ".beam")
    beam = compile_fixture(:current)
    unload_fixture()

    assert :code.add_patha(String.to_charlist(ebin)) == true
    on_exit(fn -> cleanup_fixture(ebin) end)

    File.write!(filename, beam)

    assert {:module, @fixture} =
             :code.load_binary(@fixture, String.to_charlist(filename), beam)

    assert {:error, :beam_outside_application_ebin} =
             CodeReloader.reload_module(@fixture, other_ebin)
  end

  defp compile_fixture(version) do
    line = :erl_anno.new(1)

    forms = [
      {:attribute, line, :module, @fixture},
      {:attribute, line, :export, [{:version, 0}]},
      {:function, line, :version, 0, [{:clause, line, [], [], [{:atom, line, version}]}]}
    ]

    case :compile.forms(forms, [:return_errors, :return_warnings]) do
      {:ok, @fixture, beam} ->
        beam

      {:ok, @fixture, beam, _warnings} ->
        beam

      {:error, errors, warnings} ->
        flunk("fixture compile failed: #{inspect({errors, warnings})}")
    end
  end

  defp temporary_ebin! do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbor-code-reloader-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp cleanup_fixture(ebin) do
    unload_fixture()
    _ = :code.del_path(String.to_charlist(ebin))
  end

  defp unload_fixture do
    _ = :code.soft_purge(@fixture)
    _ = :code.delete(@fixture)
    _ = :code.soft_purge(@fixture)
  end
end
