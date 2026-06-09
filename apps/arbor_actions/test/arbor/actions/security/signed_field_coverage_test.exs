defmodule Arbor.Actions.Security.Detectors.SignedFieldCoverageTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.Detectors.SignedFieldCoverage

  setup do
    dir = Path.join(System.tmp_dir!(), "sigcov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, name, src), do: File.write!(Path.join(dir, name), src)
  defp fields(dir), do: SignedFieldCoverage.detect(root: dir) |> Enum.map(& &1.evidence[:field])

  test "flags a struct field absent from signing_payload", %{dir: dir} do
    write(dir, "a.ex", """
    defmodule FixA do
      defstruct [:id, :amount, :signature]
      def signing_payload(s), do: "id=\#{s.id}"
    end
    """)

    assert fields(dir) == [:amount]
  end

  test "no finding when every field is covered", %{dir: dir} do
    write(dir, "b.ex", """
    defmodule FixB do
      defstruct [:id, :amount, :signature]
      def signing_payload(s), do: "\#{s.id}|\#{s.amount}"
    end
    """)

    assert fields(dir) == []
  end

  test "follows a local helper that references the field", %{dir: dir} do
    write(dir, "c.ex", """
    defmodule FixC do
      defstruct [:id, :amount, :signature]
      def signing_payload(s), do: build(s)
      defp build(s), do: "\#{s.id}|\#{s.amount}"
    end
    """)

    assert fields(dir) == []
  end

  test "respects @signing_excluded", %{dir: dir} do
    write(dir, "d.ex", """
    defmodule FixD do
      defstruct [:id, :transient, :signature]
      @signing_excluded [:transient]
      def excluded, do: @signing_excluded
      def signing_payload(s), do: "\#{s.id}"
    end
    """)

    assert fields(dir) == []
  end

  test "auto-excludes *signature* fields", %{dir: dir} do
    write(dir, "e.ex", """
    defmodule FixE do
      defstruct [:id, :issuer_signature]
      def signing_payload(s), do: "\#{s.id}"
    end
    """)

    assert fields(dir) == []
  end

  test "ignores modules without a signing_payload", %{dir: dir} do
    write(dir, "f.ex", """
    defmodule FixF do
      defstruct [:a, :b]
    end
    """)

    assert fields(dir) == []
  end

  test "handles typedstruct fields", %{dir: dir} do
    write(dir, "g.ex", """
    defmodule FixG do
      use TypedStruct
      typedstruct do
        field :id, String.t()
        field :secret, String.t()
        field :signature, String.t()
      end
      def signing_payload(s), do: "\#{s.id}"
    end
    """)

    assert fields(dir) == [:secret]
  end

  describe "regression against real signed structs" do
    test "capability.ex stays fully covered (C1 + @signing_excluded hold)" do
      findings = SignedFieldCoverage.detect(root: "apps/arbor_contracts")
      cap = Enum.filter(findings, &String.contains?(&1.location[:file], "capability.ex"))
      assert cap == [], "capability.ex regained an unsigned field: #{inspect(cap)}"
    end
  end
end
