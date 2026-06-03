defmodule Arbor.Orchestrator.Dot.ParserAdversarialTest do
  @moduledoc """
  Adversarial inputs to `Arbor.Orchestrator.Dot.Parser.parse/2`.

  Goal: confirm the parser fails-fast on pathological inputs without
  crashing, hanging, or leaking processes. Each case must return
  `{:ok, _}` OR `{:error, _}` within a few hundred ms. No `:exit`,
  no `MatchError` from the parser internals, no infinite loops.

  The DOT parser is the trust boundary between agent-authored DOT
  text and the engine. If an LLM (or a malicious agent) generates
  a malformed DOT, the parser is the first thing it hits. Robustness
  here is load-bearing.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Dot.Parser

  # Helper: call parse/1 with a timeout. Returns the result if it
  # completes in time; fails the test with a clear message otherwise.
  defp parse_within(source, timeout_ms \\ 1_000) do
    task = Task.async(fn -> Parser.parse(source) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        flunk("""
        Parser did not return within #{timeout_ms}ms. Either an infinite
        loop in the parser or catastrophic backtracking on this input:

          #{inspect(source, limit: 200, printable_limit: 200)}
        """)
    end
  end

  defp assert_handled(result) do
    case result do
      {:ok, _graph} -> :ok
      {:ok, _graph, _warnings} -> :ok
      {:error, _reason} -> :ok
      other -> flunk("Parser returned unexpected shape: #{inspect(other, limit: 200)}")
    end
  end

  describe "truncated / incomplete inputs" do
    test "empty string" do
      assert_handled(parse_within(""))
    end

    test "just whitespace" do
      assert_handled(parse_within("   \n\t  \r\n"))
    end

    test "only a keyword" do
      assert_handled(parse_within("digraph"))
    end

    test "digraph with no body or braces" do
      assert_handled(parse_within("digraph G"))
    end

    test "digraph with opening brace but no body or close" do
      assert_handled(parse_within("digraph G {"))
    end

    test "digraph with opening brace and one node, no close" do
      assert_handled(parse_within("digraph G {\n  a [shape=Mdiamond]"))
    end

    test "edge declared but RHS missing" do
      assert_handled(parse_within("digraph G {\n  a -> }\n"))
    end
  end

  describe "unbalanced delimiters" do
    test "node attr block never closes" do
      assert_handled(
        parse_within("""
        digraph G {
          a [type="never_closed
        }
        """)
      )
    end

    test "string attribute never closes" do
      assert_handled(
        parse_within("""
        digraph G {
          a [label="this string just keeps going forever and never closes
          b [shape=Msquare]
        }
        """)
      )
    end

    test "graph body has extra closing brace" do
      assert_handled(
        parse_within("""
        digraph G {
          a [shape=Mdiamond]
        }}
        """)
      )
    end

    test "multiple unbalanced braces" do
      assert_handled(parse_within("digraph G { { { { { }"))
    end
  end

  describe "syntactically valid but semantically broken" do
    test "empty graph body" do
      assert_handled(parse_within("digraph G {}"))
    end

    test "graph with only comments" do
      assert_handled(
        parse_within("""
        digraph G {
          // just a comment
          /* another */
        }
        """)
      )
    end

    test "edge to a node that's never declared" do
      assert_handled(
        parse_within("""
        digraph G {
          start [shape=Mdiamond]
          start -> never_declared_node
        }
        """)
      )
    end

    test "self-loop edge" do
      assert_handled(
        parse_within("""
        digraph G {
          a [shape=Mdiamond]
          a -> a
        }
        """)
      )
    end

    test "multiple digraph statements" do
      assert_handled(
        parse_within("""
        digraph G {
          a [shape=Mdiamond]
        }
        digraph H {
          b [shape=Msquare]
        }
        """)
      )
    end
  end

  describe "garbage / non-DOT input" do
    test "random ASCII bytes" do
      garbage = for _ <- 1..200, into: "", do: <<Enum.random(33..126)>>
      assert_handled(parse_within(garbage))
    end

    test "non-DOT structured content (JSON)" do
      assert_handled(parse_within(~s({"nodes": ["a", "b"], "edges": [["a", "b"]]})))
    end

    test "non-DOT structured content (YAML-like)" do
      assert_handled(parse_within("nodes:\n  - id: a\n  - id: b\n"))
    end

    test "null bytes scattered in input" do
      assert_handled(parse_within("digraph G {\0  a [shape=Mdiamond]\0\0}"))
    end

    test "BOM + valid DOT" do
      # UTF-8 BOM prefix
      assert_handled(parse_within(<<0xEF, 0xBB, 0xBF>> <> "digraph G { a [shape=Mdiamond] }"))
    end
  end

  describe "large inputs (no catastrophic time/memory)" do
    test "1000 nodes" do
      body =
        for i <- 1..1000 do
          ~s|  n#{i} [shape=Mdiamond, label="node #{i}"]\n|
        end
        |> Enum.join()

      source = "digraph G {\n#{body}}\n"

      assert_handled(parse_within(source, 5_000))
    end

    test "1000 sequential edges" do
      nodes = for i <- 0..1000, into: "", do: ~s|  n#{i} [shape=Mdiamond]\n|

      edges =
        for i <- 0..999 do
          ~s|  n#{i} -> n#{i + 1}\n|
        end
        |> Enum.join()

      source = "digraph G {\n#{nodes}#{edges}}\n"

      assert_handled(parse_within(source, 5_000))
    end

    test "deeply nested comment block" do
      nested = String.duplicate("/* ", 500) <> "inner" <> String.duplicate(" */", 500)
      source = "digraph G {\n  // comments\n#{nested}\n}\n"
      assert_handled(parse_within(source))
    end

    test "very long attribute value" do
      long_label = String.duplicate("a", 100_000)
      source = ~s|digraph G {\n  n [label="#{long_label}"]\n}\n|
      assert_handled(parse_within(source))
    end
  end

  describe "edge-case quoting and escaping" do
    test "escaped quote inside string" do
      assert_handled(parse_within(~S(digraph G {
        n [label="she said \"hello\" loudly"]
      })))
    end

    test "backslash at end of string" do
      assert_handled(parse_within(~S(digraph G {
        n [label="trailing backslash \\"]
      })))
    end

    test "newline inside quoted attribute" do
      assert_handled(parse_within("digraph G {\n  n [label=\"line1\nline2\"]\n}\n"))
    end

    test "empty string attribute value" do
      assert_handled(parse_within(~s|digraph G {\n  n [label=""]\n}\n|))
    end

    test "unicode in identifiers and values" do
      assert_handled(parse_within(~s|digraph G {\n  node_β [label="héllo wörld 🚀"]\n}\n|))
    end
  end

  describe "trailing content after digraph close (rejected as of HEAD)" do
    # The parser used to stop at the first closing `}` and silently
    # drop everything after it. That let LLM-generated DOTs hide a
    # partial follow-up, a hallucinated second graph, or a stray
    # statement — and operators had no signal that the pipeline they
    # meant to run wasn't the one that ran. Now:
    #
    #   - default mode returns {:error, "trailing content..."}
    #   - accumulate_errors: true returns {:ok, graph, [warning, ...]}
    #
    # These tests pin the new behavior so a future regression is
    # visible.

    test "content after closing brace is now rejected as an error" do
      result =
        parse_within("digraph G { a [shape=Mdiamond] } b [shape=Msquare] start -> a -> b")

      assert {:error, reason} = result
      assert reason =~ "trailing content"
      assert reason =~ "b"
    end

    test "second digraph statement is now rejected as trailing content" do
      result =
        parse_within("digraph G { a [shape=Mdiamond] } digraph H { b [shape=Msquare] }")

      assert {:error, reason} = result
      assert reason =~ "trailing content"
      assert reason =~ "digraph H"
    end

    test "accumulate_errors=true surfaces trailing content as a warning" do
      result =
        Parser.parse(
          "digraph G { a [shape=Mdiamond] } b [shape=Msquare] start -> a -> b",
          accumulate_errors: true
        )

      assert {:ok, graph, warnings} = result
      assert Map.keys(graph.nodes) == ["a"]

      assert Enum.any?(warnings, fn w ->
               is_binary(w) and String.contains?(w, "trailing content")
             end),
             "expected a 'trailing content' warning in #{inspect(warnings)}"
    end
  end

  describe "malicious-looking attribute patterns" do
    test "path-traversal in graph_file attr (not the parser's job to reject, just to parse)" do
      assert_handled(
        parse_within("""
        digraph G {
          invoke [type="graph.invoke", graph_file="../../../etc/passwd"]
        }
        """)
      )
    end

    test "shell-meta in attribute values" do
      assert_handled(parse_within(~s|digraph G {\n  n [label="; rm -rf / #"]\n}\n|))
    end

    test "very long single line (no newlines)" do
      one_line = "digraph G { " <> String.duplicate("n [shape=Mdiamond] ", 200) <> "}"
      assert_handled(parse_within(one_line))
    end
  end
end
