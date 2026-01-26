defmodule ArborEval.Checks.DocumentationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias ArborEval.Checks.Documentation

  describe "moduledoc checks" do
    test "detects missing moduledoc" do
      ast =
        quote do
          defmodule Test do
            def test(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :missing_moduledoc))
    end

    test "passes with moduledoc present" do
      ast =
        quote do
          defmodule Test do
            @moduledoc "A test module with sufficient documentation"
            def test(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast})

      refute Enum.any?(result.violations, &(&1.type == :missing_moduledoc))
    end

    test "flags short moduledoc" do
      ast =
        quote do
          defmodule Test do
            @moduledoc "Short"
            def test(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :short_moduledoc))
    end

    test "accepts @moduledoc false" do
      # Build AST from code to ensure @moduledoc false is preserved correctly
      code = """
      defmodule Test do
        @moduledoc false
        def test(), do: :ok
      end
      """

      {:ok, ast} = Code.string_to_quoted(code)
      result = Documentation.run(%{ast: ast})

      # Should not have missing_moduledoc violations when @moduledoc false is present
      moduledoc_violations = Enum.filter(result.violations, &(&1.type == :missing_moduledoc))
      assert moduledoc_violations == []
    end
  end

  describe "function doc checks" do
    test "detects missing @doc on public function" do
      ast =
        quote do
          defmodule Test do
            @moduledoc "A test module"
            def public_function(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :missing_doc))
    end

    test "passes with @doc present" do
      ast =
        quote do
          defmodule Test do
            @moduledoc "A test module"

            @doc "Does something useful"
            def documented_function(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast})

      refute Enum.any?(result.violations, fn v ->
               v.type == :missing_doc and String.contains?(v.message, "documented_function")
             end)
    end

    test "accepts @doc false when allowed" do
      ast =
        quote do
          defmodule Test do
            @moduledoc "A test module"

            @doc false
            def hidden_function(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast, allow_doc_false: true})

      refute Enum.any?(result.violations, fn v ->
               v.type == :doc_false and String.contains?(v.message, "hidden_function")
             end)
    end

    test "skips OTP callbacks" do
      ast =
        quote do
          defmodule Test do
            @moduledoc "A GenServer"

            def init(args), do: {:ok, args}
            def handle_call(msg, _from, state), do: {:reply, msg, state}
            def handle_cast(msg, state), do: {:noreply, state}
          end
        end

      result = Documentation.run(%{ast: ast})

      # Should not flag init, handle_call, handle_cast
      refute Enum.any?(result.violations, fn v ->
               v.type == :missing_doc and
                 (String.contains?(v.message, "init") or
                    String.contains?(v.message, "handle_call") or
                    String.contains?(v.message, "handle_cast"))
             end)
    end
  end

  describe "multi-clause function handling" do
    test "does not flag secondary clauses when first clause has @doc" do
      code = """
      defmodule Test do
        @moduledoc "A test module"

        @doc "Check if session has expired."
        def expired?(%{expires_at: nil}), do: false
        def expired?(%{expires_at: expires_at}) do
          DateTime.compare(DateTime.utc_now(), expires_at) == :gt
        end
      end
      """

      {:ok, ast} = Code.string_to_quoted(code)
      result = Documentation.run(%{ast: ast})

      # Should not flag any expired? function
      missing_doc_violations = Enum.filter(result.violations, fn v ->
        v.type == :missing_doc and String.contains?(v.message, "expired?")
      end)

      assert missing_doc_violations == [], "Multi-clause function should not trigger missing_doc violation"
    end

    test "does not flag three-clause functions when first clause has @doc" do
      code = """
      defmodule Test do
        @moduledoc "A test module"

        @doc "Process different inputs."
        def process(:atom), do: :atom_result
        def process(number) when is_integer(number), do: number * 2
        def process(string) when is_binary(string), do: String.upcase(string)
      end
      """

      {:ok, ast} = Code.string_to_quoted(code)
      result = Documentation.run(%{ast: ast})

      missing_doc_violations = Enum.filter(result.violations, fn v ->
        v.type == :missing_doc and String.contains?(v.message, "process")
      end)

      assert missing_doc_violations == []
    end

    test "flags first clause when no @doc is present on multi-clause function" do
      code = """
      defmodule Test do
        @moduledoc "A test module"

        def undocumented(:one), do: 1
        def undocumented(:two), do: 2
      end
      """

      {:ok, ast} = Code.string_to_quoted(code)
      result = Documentation.run(%{ast: ast})

      # Should flag exactly one missing_doc for undocumented
      missing_doc_violations = Enum.filter(result.violations, fn v ->
        v.type == :missing_doc and String.contains?(v.message, "undocumented")
      end)

      assert length(missing_doc_violations) == 1
    end

    test "handles mixed documented and undocumented multi-clause functions" do
      code = """
      defmodule Test do
        @moduledoc "A test module"

        @doc "This one is documented"
        def documented(:a), do: :a
        def documented(:b), do: :b

        def undocumented(:x), do: :x
        def undocumented(:y), do: :y
      end
      """

      {:ok, ast} = Code.string_to_quoted(code)
      result = Documentation.run(%{ast: ast})

      # Should not flag documented
      doc_violations_for_documented = Enum.filter(result.violations, fn v ->
        v.type == :missing_doc and String.contains?(v.message, "'documented/")
      end)
      assert doc_violations_for_documented == []

      # Should flag undocumented exactly once
      doc_violations_for_undocumented = Enum.filter(result.violations, fn v ->
        v.type == :missing_doc and String.contains?(v.message, "'undocumented/")
      end)
      assert length(doc_violations_for_undocumented) == 1
    end
  end

  describe "configuration" do
    test "can disable moduledoc requirement" do
      ast =
        quote do
          defmodule Test do
            def test(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast, require_moduledoc: false})

      refute Enum.any?(result.violations, &(&1.type == :missing_moduledoc))
    end

    test "can disable function doc requirement" do
      ast =
        quote do
          defmodule Test do
            @moduledoc "Test module"
            def undocumented(), do: :ok
          end
        end

      result = Documentation.run(%{ast: ast, require_doc: false})

      refute Enum.any?(result.violations, &(&1.type == :missing_doc))
    end
  end
end
