defmodule Arbor.Commands.SafeRecoveryArtifact.ParseTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.Parse
  alias Arbor.Commands.SafeRecoveryArtifactFixture, as: Fixture

  @moduletag :fast

  describe "app_spec/1" do
    test "parses generated Mix-style app terms" do
      assert {:ok, spec} = Parse.app_spec(Fixture.app_body("arbor_trust"))
      assert spec.name == "arbor_trust"
      assert spec.version == "0.1.0"
      assert spec.required == ["kernel"]
      assert spec.included == []
      assert spec.optional == []
    end

    test "accepts quoted atoms, escapes, and comments" do
      bytes =
        "% comment\n{application,'arbor_trust',[{vsn,\"0.1.0\"},{modules,['Elixir.Foo\\n']},{applications,[]}]}."

      assert {:ok, spec} = Parse.app_spec(bytes)
      assert spec.name == "arbor_trust"
    end

    test "defaults missing dependency lists" do
      assert {:ok, spec} = Parse.app_spec("{application,foo,[{vsn,\"1\"}]}.")
      assert spec.required == []
    end

    test "rejects unknown property keys without interning" do
      assert {:error, :unknown_atom} =
               Parse.app_spec("{application,foo,[{vsn,\"1\"},{nope,1}]}.")
    end

    test "rejects unknown head atoms" do
      assert {:error, :unknown_atom} = Parse.app_spec("{other,foo,[{vsn,\"1\"}]}.")
    end

    test "rejects duplicate properties" do
      assert {:error, :duplicate_property} =
               Parse.app_spec("{application,foo,[{vsn,\"1\"},{vsn,\"2\"}]}.")
    end

    test "rejects malformed dependency lists" do
      assert {:error, :invalid_dependency_list} =
               Parse.app_spec("{application,foo,[{vsn,\"1\"},{applications,1}]}.")

      assert {:error, :invalid_dependency_list} =
               Parse.app_spec("{application,foo,[{vsn,\"1\"},{applications,[kernel,kernel]}]}.")

      assert {:error, :invalid_dependency_list} =
               Parse.app_spec(
                 "{application,foo,[{vsn,\"1\"},{applications,[kernel]},{included_applications,[kernel]}]}."
               )
    end

    test "rejects variables, calls, trailing terms, and floats" do
      assert {:error, :variable} = Parse.app_spec("{application,Foo,[{vsn,\"1\"}]}.")
      assert {:error, :executable_form} = Parse.app_spec("{application,foo(1),[{vsn,\"1\"}]}.")
      assert {:error, :trailing_terms} = Parse.app_spec("{application,foo,[{vsn,\"1\"}]}. 1.")
      assert {:error, :unsupported_syntax} = Parse.app_spec("{application,foo,[{vsn,1.0}]}.")
    end

    test "rejects octal escapes above 255 and hidden controls" do
      assert {:error, :unsupported_syntax} =
               Parse.app_spec("{application,foo,[{vsn,\"\\400\"}]}.")

      assert {:error, :control_character} =
               Parse.app_spec("% \0 hidden\n{application,foo,[{vsn,\"1\"}]}.")

      assert {:error, :invalid_utf8} =
               Parse.app_spec(<<0xFF, 0xFF, "{application,foo,[{vsn,\"1\"}]}."::binary>>)
    end

    test "rejects maps, improper lists, and missing terminator" do
      assert {:error, :unsupported_syntax} = Parse.app_spec(~S({application,foo,#{a=>1}}.))
      assert {:error, :improper_list} = Parse.app_spec("{application,foo,[{vsn,\"1\"}|x]}.")
      assert {:error, :malformed_term} = Parse.app_spec("{application,foo,[{vsn,\"1\"}]}")
    end

    test "parses a long integer list with an explicit item count" do
      items = Enum.map_join(1..2_048, ",", &Integer.to_string/1)
      assert {:ok, list} = Parse.term("[" <> items <> "].")
      assert length(list) == 2_048
    end

    test "rejects oversized and overly nested terms" do
      huge = "{application,foo,[{vsn,\"" <> String.duplicate("a", 256 * 1024) <> "\"}]}."
      assert {:error, :unbounded} = Parse.app_spec(huge)

      deep = Enum.reduce(1..65, "1", fn _i, acc -> "[" <> acc <> "]" end) <> "."
      assert {:error, :nesting_exceeded} = Parse.term(deep)
    end
  end

  describe "release/1" do
    test "parses Mix 2-tuple apps as permanent" do
      assert {:ok, rel} = Parse.release(Fixture.rel_body())
      assert rel.name == "arbor_trust"
      assert rel.version == "0.1.0"
      assert rel.erts == "16.3"
      assert Enum.map(rel.apps, & &1.start_type) |> Enum.uniq() == ["permanent"]
    end

    test "parses OTP tuple form with start types and rel info" do
      bytes =
        "{release,{arbor_trust,\"0.1.0\"},{erts,\"16.3\"},[{kernel,\"1.0.0\",load}],[unix]}."

      assert {:ok, rel} = Parse.release(bytes)
      assert hd(rel.apps).start_type == "load"
    end

    test "rejects unknown start types" do
      bytes = "{release,n,v,\"16.3\",[{kernel,\"1\",weird}]}."
      assert {:error, :invalid_start_type} = Parse.release(bytes)
    end
  end

  describe "atom safety" do
    @tag :slow
    test "many unique unknown atom spellings do not increase atom_count" do
      before = :erlang.system_info(:atom_count)

      Enum.each(1..2_000, fn index ->
        name = "u" <> String.pad_leading(Integer.to_string(index), 6, "0") <> "z"
        bytes = "{application,#{name},[{vsn,\"1\"}]}."
        assert {:ok, spec} = Parse.app_spec(bytes)
        assert spec.name == name
      end)

      after_count = :erlang.system_info(:atom_count)
      assert after_count == before
    end
  end
end
