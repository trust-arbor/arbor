defmodule Arbor.Actions.Security.Detectors.UriRegistrationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.Detectors.UriRegistration

  setup do
    dir = Path.join(System.tmp_dir!(), "urireg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, name, src), do: File.write!(Path.join(dir, name), src)
  defp uris(dir), do: UriRegistration.detect(root: dir) |> Enum.map(& &1.evidence[:uri])

  test "flags a URI whose namespace is not in the registry", %{dir: dir} do
    write(dir, "a.ex", """
    defmodule A do
      def go, do: Arbor.Security.authorize("agent_x", "arbor://zzznotreal/do/thing", :execute)
    end
    """)

    assert "arbor://zzznotreal/do/thing" in uris(dir)
  end

  test "does not flag a registered namespace", %{dir: dir} do
    write(dir, "b.ex", """
    defmodule B do
      def go, do: Arbor.Security.authorize("agent_x", "arbor://fs/read/docs", :execute)
    end
    """)

    assert uris(dir) == []
  end

  test "does not flag a generated action namespace URI", %{dir: dir} do
    write(dir, "action.ex", """
    defmodule ActionUri do
      def go, do: Arbor.Security.authorize("agent_x", "arbor://action/git/status", :execute)
    end
    """)

    assert uris(dir) == []
  end

  test "flags the retired plural action namespace", %{dir: dir} do
    write(dir, "legacy_action.ex", """
    defmodule LegacyActionUri do
      def go, do: Arbor.Security.authorize("agent_x", "arbor://actions/execute/git.status", :execute)
    end
    """)

    assert "arbor://actions/execute/git.status" in uris(dir)
  end

  test "does not flag a wildcard grant on a registered namespace", %{dir: dir} do
    write(dir, "c.ex", """
    defmodule C do
      @grant %{resource_uri: "arbor://fs/**"}
      def grant, do: @grant
    end
    """)

    assert uris(dir) == []
  end

  test "gives interpolated URIs on a registered namespace the benefit of the doubt", %{dir: dir} do
    write(dir, "d.ex", """
    defmodule D do
      def go(op), do: Arbor.Security.authorize("a", "arbor://fs/\#{op}", :execute)
    end
    """)

    assert uris(dir) == []
  end

  test "excludes URIs that appear only in documentation", %{dir: dir} do
    write(dir, "e.ex", """
    defmodule E do
      @moduledoc \"\"\"
      Example: grant "arbor://zzzdocsonly/example" to an agent.
      \"\"\"
      def noop, do: :ok
    end
    """)

    assert uris(dir) == []
  end

  test "excludes provenance URIs in a *_source function (not a capability)", %{dir: dir} do
    write(dir, "src.ex", """
    defmodule Src do
      defp bridge_source(id), do: "arbor://zzzsource/\#{id}"
      def emit(id), do: %{source: bridge_source(id)}
    end
    """)

    assert uris(dir) == []
  end

  test "flags an unregistered interpolated namespace (the signals-gap class)", %{dir: dir} do
    write(dir, "f.ex", """
    defmodule F do
      def go(topic), do: subscribe("arbor://zzztopic/subscribe/\#{topic}")
      defp subscribe(_), do: :ok
    end
    """)

    assert "arbor://zzztopic/subscribe/" in uris(dir)
  end
end
