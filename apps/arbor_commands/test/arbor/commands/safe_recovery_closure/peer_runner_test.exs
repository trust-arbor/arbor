defmodule Arbor.Commands.SafeRecoveryClosure.PeerRunnerTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeRecoveryClosure.PeerRunner

  @moduletag :slow
  @moduletag timeout: 180_000

  test "peer starts a fixture app, injects RELEASE_COOKIE, and shuts down bounded" do
    root = fixture_release!()
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, sample} = PeerRunner.__test_measure__(root, ["e0b3_fixture"])

    assert sample["observations"]["cookie_set"] == true
    refute Map.has_key?(sample, "cookie")
    refute inspect(sample) =~ "RELEASE_COOKIE="

    names = Enum.map(sample["post_start"]["applications"], & &1["name"])
    assert "e0b3_fixture" in names
    refute "arbor_commands" in names

    assert sample["shutdown"]["status"] == "bounded"
    assert sample["shutdown"]["remaining_names"] == []
    refute "e0b3_fixture" in Enum.map(sample["pre_start"]["applications"], & &1["name"])
  end

  test "layout rejects a cookie before any peer starts" do
    root = fixture_release!()
    File.mkdir_p!(Path.join(root, "releases"))
    File.write!(Path.join(root, "releases/COOKIE"), "secret\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :cookie_present} = PeerRunner.measure(root)
  end

  defp fixture_release! do
    root =
      Path.join(
        System.tmp_dir!(),
        "e0b3-peer-#{System.unique_integer([:positive, :monotonic])}"
      )

    ebin = Path.join(root, "lib/e0b3_fixture-0.1.0/ebin")
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "e0b3_fixture.app"),
      """
      {application, e0b3_fixture, [
        {description, "e0b3 fixture"},
        {vsn, "0.1.0"},
        {modules, ['Elixir.E0B3Fixture']},
        {registered, []},
        {applications, [kernel, stdlib]}
      ]}.
      """
    )

    [{E0B3Fixture, bin}] =
      Code.compile_string("""
      defmodule E0B3Fixture do
        def hello, do: :ok
      end
      """)

    File.write!(Path.join(ebin, "Elixir.E0B3Fixture.beam"), bin)
    root
  end
end
