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
               Parse.app_spec(~s({application,foo,[{vsn,"1"},{vsn,"2"}]}.))
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

    test "admits Mix compile_env and Hex package metadata keys" do
      bytes =
        "{application,tesla,[{vsn,\"1.16.0\"},{compile_env,[{tesla,[logger],error}]},{doc,\"doc\"},{include_files,[\"mix.exs\"]}]}."

      assert {:ok, spec} = Parse.app_spec(bytes)
      assert spec.name == "tesla"
    end

    test "admits Mix-shaped optional apps that also appear in applications" do
      assert {:ok, parsed} =
               Parse.app_spec(
                 "{application,jason,[{vsn,\"1.4.5\"},{applications,[kernel,stdlib,elixir,decimal]},{optional_applications,[decimal]}]}."
               )

      assert parsed.required == ["kernel", "stdlib", "elixir", "decimal"]
      assert parsed.optional == ["decimal"]
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

    test "security regression: rejects octal-decoded controls and keeps symbolic escapes" do
      assert {:ok, newline} = Parse.app_spec("{application,foo,[{vsn,\"a\\nb\"}]}.")
      assert newline.version == "a\nb"

      assert {:ok, tab} = Parse.app_spec("{application,foo,[{vsn,\"a\\tb\"}]}.")
      assert tab.version == "a\tb"

      assert {:ok, cr} = Parse.app_spec("{application,foo,[{vsn,\"a\\rb\"}]}.")
      assert cr.version == "a\rb"

      assert {:error, :control_character} =
               Parse.app_spec("{application,foo,[{vsn,\"\\000\"}]}.")

      assert {:error, :control_character} =
               Parse.app_spec("{application,foo,[{vsn,\"\\001\"}]}.")

      assert {:error, :control_character} =
               Parse.app_spec("{application,foo,[{vsn,\"\\011\"}]}.")

      assert {:error, :control_character} =
               Parse.app_spec("{application,foo,[{vsn,\"\\012\"}]}.")

      assert {:error, :control_character} =
               Parse.app_spec("{application,foo,[{vsn,\"\\015\"}]}.")

      assert {:error, :control_character} =
               Parse.app_spec("{application,foo,[{vsn,\"\\177\"}]}.")

      assert {:error, :control_character} =
               Parse.app_spec("{application,foo,[{vsn,\"\\200\"}]}.")

      assert {:error, :unsupported_syntax} =
               Parse.app_spec("{application,foo,[{vsn,\"\\400\"}]}.")
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

    test "security regression: integer binary items hit the 16_384-item ceiling" do
      # The binary-specific item ceiling is independent of the global parsed-value
      # ceiling because the entire binary literal is one parsed value.
      accepted = integer_binary_term(16_384)
      assert {:ok, bytes} = Parse.term(accepted)
      assert byte_size(bytes) == 16_384

      rejected = integer_binary_term(16_385)
      assert {:error, :unbounded} = Parse.term(rejected)
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
    test "many unique unknown atom spellings are not interned" do
      Enum.each(1..2_000, fn index ->
        name = "u" <> String.pad_leading(Integer.to_string(index), 6, "0") <> "z"
        bytes = "{application,#{name},[{vsn,\"1\"}]}."
        assert {:ok, spec} = Parse.app_spec(bytes)
        assert spec.name == name
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end)
    end
  end

  defp integer_binary_term(count) do
    "<<" <> Enum.map_join(1..count, ",", fn _index -> "1" end) <> ">>."
  end
end
