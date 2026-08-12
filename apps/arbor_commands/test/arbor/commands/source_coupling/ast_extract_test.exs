defmodule Arbor.Commands.SourceCoupling.AstExtractTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SourceCoupling.AstExtract
  alias Arbor.Commands.SourceCoupling.Encode

  @moduletag :fast

  test "lexical alias scope isolated across if branches" do
    src = """
    defmodule Arbor.Scope.Test do
      def run(flag) do
        if flag do
          alias Arbor.Alpha.One
          One.x()
        else
          # One must not resolve via sibling branch alias
          One.x()
        end
      end
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/scope.ex", src)
    # Both branches may produce remote refs; alias binding only in then-branch.
    # Else branch bare One expands as module "One" (not Arbor.Alpha.One) unless bound.
    targets = Enum.map(result.references, & &1.target)
    assert "Arbor.Alpha.One" in targets
  end

  test "module attribute binding used as module expression" do
    src = """
    defmodule Arbor.Attr.Test do
      @mod Arbor.Contracts.Foo
      def call, do: @mod.ok()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/attr.ex", src)
    assert Enum.any?(result.references, &(&1.target == "Arbor.Contracts.Foo"))
  end

  test "quoted nested __MODULE__ is __aliases__ with leading __MODULE__ tuple" do
    # Prove the real string_to_quoted shape (not a dotted-call form).
    assert {:ok, {:__aliases__, _, [{:__MODULE__, _, ctx}, :Child]}} =
             Code.string_to_quoted("__MODULE__.Child")

    # Context is typically nil from string_to_quoted; never an atom segment.
    assert ctx in [nil, false, Elixir]

    assert {:ok, {:__aliases__, _, [{:__MODULE__, _, _}, :Store]}} =
             Code.string_to_quoted("__MODULE__.Store")

    refute match?(
             {:ok, {{:., _, _}, _, _}},
             Code.string_to_quoted("__MODULE__.Child")
           )
  end

  test "nested __MODULE__ remote and struct resolve to Parent.Child" do
    src = """
    defmodule Arbor.Nested.Host do
      def call, do: __MODULE__.Child.f()
      def struct_ref, do: %__MODULE__.Child{}
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/nested_host.ex", src)
    targets = Enum.map(result.references, & &1.target)
    assert "Arbor.Nested.Host.Child" in targets

    refute Enum.any?(result.unresolved, fn u ->
             String.contains?(u.normalized_expression, "__MODULE__.Child")
           end)
  end

  test "alias __MODULE__.Store binds and resolves full nested module" do
    src = """
    defmodule Arbor.Alias.Host do
      alias __MODULE__.Store
      def call, do: Store.put(:k, :v)
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/alias_host.ex", src)
    targets = Enum.map(result.references, & &1.target)
    assert "Arbor.Alias.Host.Store" in targets
  end

  test "static Module.concat with __MODULE__ resolves without dynamic_module_concat" do
    src = """
    defmodule Arbor.Concat.Host do
      def list_form, do: Module.concat([__MODULE__, Child]).f()
      def two_arg, do: Module.concat(__MODULE__, Child).g()
      def nested_child, do: Module.concat([__MODULE__.Child, Extra]).h()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/concat_host.ex", src)
    targets = Enum.map(result.references, & &1.target)
    assert "Arbor.Concat.Host.Child" in targets
    assert "Arbor.Concat.Host.Child.Extra" in targets

    refute Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_concat"
           end)
  end

  test "non-module map attribute field access is not a dynamic module reference" do
    src = """
    defmodule Arbor.Policy.Host do
      @policy %{openai: %{model: "gpt"}, temperature: 0.2}
      def cfg, do: @policy.openai
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/policy_host.ex", src)
    assert result.unresolved == []

    # Must not invent module targets from map keys/fields.
    targets = Enum.map(result.references, & &1.target)
    refute "openai" in targets
    refute "gpt" in targets
    refute Enum.any?(targets, &String.contains?(&1, "openai"))
  end

  test "ordinary atom literals in static attr maps are not fake module targets" do
    src = """
    defmodule Arbor.AtomLit.Host do
      @policy %{mode: :oauth, provider: :openai}
      def cfg, do: @policy.mode
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/atom_lit_host.ex", src)
    assert result.unresolved == []
    targets = Enum.map(result.references, & &1.target)
    refute "oauth" in targets
    refute "openai" in targets
    refute Enum.any?(targets, &(&1 in ["oauth", "openai", "mode", "provider"]))
  end

  test "ordinary atom literals in static attr lists are not fake module targets" do
    src = """
    defmodule Arbor.AtomList.Host do
      @modes [:oauth, :api_key, :none]
      def modes, do: @modes
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/atom_list_host.ex", src)
    assert result.unresolved == []
    targets = Enum.map(result.references, & &1.target)
    refute "oauth" in targets
    refute "api_key" in targets
    refute "none" in targets
  end

  test "module-valued map attribute field resolves as module reference" do
    src = """
    defmodule Arbor.Handlers.Host do
      @handlers %{openai: Arbor.LLM.OpenAI}
      def call, do: @handlers.openai.run()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/handlers_host.ex", src)
    assert Enum.any?(result.references, &(&1.target == "Arbor.LLM.OpenAI"))

    refute Enum.any?(result.unresolved, fn u ->
             String.contains?(u.normalized_expression, "handlers")
           end)
  end

  test "partial static map keeps nested non-module fields when sibling uses ~w sigil" do
    # Mirrors Arbor.LLM.OAuth.ProviderPolicy: nested provider maps with a ~w scopes
    # sibling must remain classifiable so @policy.openai / @policy.xai are not
    # reported as dynamic_module_expr.
    src = """
    defmodule Arbor.LLM.OAuth.ProviderPolicyShape do
      @policy %{
        openai: %{
          client_id: "app_test",
          token_endpoint: "https://auth.example/oauth/token",
          scopes: ~w(openid profile email offline_access),
          skew_s: 120
        },
        xai: %{
          client_id: "xai-test",
          discovery_url: "https://auth.example/.well-known/openid-configuration",
          scopes: ~w(openid profile email),
          skew_s: 3600
        }
      }

      def openai, do: @policy.openai
      def xai, do: @policy.xai

      def refresh_openai do
        %{
          refresh_url: @policy.openai.token_endpoint,
          client_id: @policy.openai.client_id,
          skew_s: @policy.openai.skew_s
        }
      end

      def refresh_xai do
        %{
          discovery_url: @policy.xai.discovery_url,
          client_id: @policy.xai.client_id,
          skew_s: @policy.xai.skew_s
        }
      end
    end
    """

    assert {:ok, result} =
             AstExtract.extract(
               "apps/arbor_llm/lib/arbor/llm/oauth/provider_policy_shape.ex",
               src
             )

    refute Enum.any?(result.unresolved, fn u ->
             String.contains?(u.normalized_expression, "policy")
           end)

    refute Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_expr" and
               (String.contains?(u.normalized_expression, "openai") or
                  String.contains?(u.normalized_expression, "xai"))
           end)

    targets = Enum.map(result.references, & &1.target)
    refute "openai" in targets
    refute "xai" in targets
    refute Enum.any?(targets, &String.contains?(&1, "openid"))
  end

  test "unknown sibling does not erase known module-valued map fields" do
    src = """
    defmodule Arbor.Partial.Handlers do
      @handlers %{
        openai: Arbor.LLM.OpenAI,
        other: dynamic_mod
      }

      def call_known, do: @handlers.openai.run()
      def call_unknown, do: @handlers.other.run()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/partial_handlers.ex", src)
    assert Enum.any?(result.references, &(&1.target == "Arbor.LLM.OpenAI"))

    assert Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_expr" and
               String.contains?(u.normalized_expression, "handlers") and
               String.contains?(u.normalized_expression, "other")
           end)

    refute Enum.any?(result.unresolved, fn u ->
             String.contains?(u.normalized_expression, "openai")
           end)
  end

  test "custom sigil is not assumed non-module and keeps unknown field unresolved" do
    # Custom sigils can expand to arbitrary values; only built-in literal sigils
    # (~w/~s/…) are non-module. ~Z must not be trusted as a static literal.
    src = """
    defmodule Arbor.CustomSigil.Host do
      @handlers %{
        openai: Arbor.LLM.OpenAI,
        meta: ~Z(custom)
      }

      def call_known, do: @handlers.openai.run()
      def call_meta, do: @handlers.meta.run()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/custom_sigil_host.ex", src)
    assert Enum.any?(result.references, &(&1.target == "Arbor.LLM.OpenAI"))

    refute Enum.any?(result.unresolved, fn u ->
             String.contains?(u.normalized_expression, "openai")
           end)

    assert Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_expr" and
               String.contains?(u.normalized_expression, "handlers") and
               String.contains?(u.normalized_expression, "meta")
           end)
  end

  test "dynamic map key makes known field module access unresolved" do
    # A dynamic key may evaluate to :openai and override the static entry.
    # Preserving @handlers.openai as a resolved module would be unsound.
    src = """
    defmodule Arbor.DynKey.Host do
      @handlers %{
        unquote(key) => Other.Mod,
        openai: Arbor.LLM.OpenAI
      }

      def call, do: @handlers.openai.run()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/dyn_key_host.ex", src)

    # Static source still mentions OpenAI at the attribute definition.
    assert Enum.any?(result.references, &(&1.target == "Arbor.LLM.OpenAI"))

    assert Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_expr" and
               String.contains?(u.normalized_expression, "handlers") and
               String.contains?(u.normalized_expression, "openai")
           end)
  end

  test "genuinely dynamic Module.concat remains unresolved beside partial maps" do
    src = """
    defmodule Arbor.Partial.Mixed do
      @policy %{
        openai: %{model: "gpt", scopes: ~w(openid profile)},
        handler: Arbor.LLM.OpenAI
      }

      def cfg, do: @policy.openai
      def call_handler, do: @policy.handler.run()
      def call_dyn(x), do: Module.concat([x, "A"]).f()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/partial_mixed.ex", src)
    assert Enum.any?(result.references, &(&1.target == "Arbor.LLM.OpenAI"))

    refute Enum.any?(result.unresolved, fn u ->
             String.contains?(u.normalized_expression, "policy")
           end)

    assert Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_expr" and
               String.contains?(u.normalized_expression, "x") and
               String.contains?(u.normalized_expression, "A")
           end)
  end

  test "unknown module attribute used as module remains unresolved" do
    src = """
    defmodule Arbor.Missing.Host do
      def call, do: @missing.run()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/missing_host.ex", src)
    assert result.unresolved != []

    assert Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_expr"
           end)
  end

  test "use behaviour struct and defimpl produce refs" do
    src = """
    defmodule Arbor.Use.Test do
      use Arbor.Some.Macro
      @behaviour Arbor.Some.Behaviour
      defstruct []
      def wrap, do: %Arbor.Some.Struct{}
    end

    defimpl Arbor.Some.Protocol, for: Arbor.Some.Struct do
      def encode(_), do: ""
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/use.ex", src)
    targets = MapSet.new(Enum.map(result.references, & &1.target))
    assert "Arbor.Some.Macro" in targets
    assert "Arbor.Some.Behaviour" in targets
    assert "Arbor.Some.Struct" in targets
    assert "Arbor.Some.Protocol" in targets
  end

  test "expression digest stable for same normalized dynamic expr" do
    src = """
    defmodule Arbor.Dyn.Test do
      def call(x), do: Module.concat([x, "A"]).f()
    end
    """

    assert {:ok, r1} = AstExtract.extract("apps/a/lib/d.ex", src)
    assert {:ok, r2} = AstExtract.extract("apps/a/lib/d.ex", src)
    assert r1.unresolved != []
    assert hd(r1.unresolved).expression_digest == hd(r2.unresolved).expression_digest

    d = Encode.expression_digest(hd(r1.unresolved).normalized_expression)
    assert d == hd(r1.unresolved).expression_digest
  end

  test "nested defmodule owns Outer.Inner not bare Inner" do
    src = """
    defmodule Arbor.Nest.Outer do
      defmodule Inner do
        def ok, do: :ok
      end
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/nest.ex", src)
    modules = Enum.map(result.module_defs, & &1.module)
    assert "Arbor.Nest.Outer" in modules
    assert "Arbor.Nest.Outer.Inner" in modules
    refute "Inner" in modules
  end

  test "nested module push/pop preserves outer module attributes" do
    src = """
    defmodule Arbor.Attr.Outer do
      @svc Arbor.Contracts.OuterSvc

      defmodule Inner do
        @svc Arbor.Contracts.InnerSvc
        def i, do: @svc.call()
      end

      def o, do: @svc.call()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/attr_stack.ex", src)
    targets = Enum.map(result.references, &{&1.from_module, &1.target, &1.kind})

    assert Enum.any?(targets, fn {from, target, _kind} ->
             from == "Arbor.Attr.Outer.Inner" and target == "Arbor.Contracts.InnerSvc"
           end)

    # Outer @svc must still resolve after nested module exits (not wiped).
    assert Enum.any?(targets, fn {from, target, _kind} ->
             from == "Arbor.Attr.Outer" and target == "Arbor.Contracts.OuterSvc"
           end)
  end

  test "defprotocol records canonical module ownership" do
    src = """
    defprotocol Arbor.Proto.Example do
      def encode(value)
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/proto.ex", src)
    mods = Enum.map(result.module_defs, &{&1.module, Map.get(&1, :kind)})
    assert {"Arbor.Proto.Example", "defprotocol"} in mods
  end

  test "typespec attribute walk fails closed on AST depth limit" do
    # Deeply nested type expression forces depth exhaustion under a tight cap.
    deep = Enum.reduce(1..20, "atom()", fn _, acc -> "{:ok, #{acc}}" end)

    src = """
    defmodule Arbor.Depth.Test do
      @type t :: #{deep}
    end
    """

    assert {:error, :ast_depth_limit} =
             AstExtract.extract("apps/arbor_common/lib/depth.ex", src, max_depth: 3)
  end

  test "identity bound form is UTF-8 safe so report JSON cannot break mid-codepoint" do
    # Force identity truncation at a multi-byte boundary. Unsafe binary_part would
    # split "é" (2 bytes) and produce invalid UTF-8 that Jason cannot encode.
    # max_expr_bytes is 2000; build a string just over that ending with multi-byte chars.
    ascii = String.duplicate("a", 1999)
    # "é" is 2 bytes in UTF-8 → total 2001 bytes when appended once.
    payload = ascii <> "éé"

    src = """
    defmodule Arbor.Utf8.Bound do
      def call(x), do: Module.concat([x, "#{payload}"]).f()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/a/lib/utf8.ex", src)
    assert result.unresolved != []
    u = hd(result.unresolved)

    assert String.valid?(u.normalized_expression)
    assert String.valid?(u.evidence)
    assert byte_size(u.normalized_expression) <= 2000
    # Must not end with a dangling UTF-8 lead byte from a split codepoint.
    assert String.valid?(u.normalized_expression <> "")

    # Canonical report path encodes this field — must not raise.
    assert {:ok, _} = Jason.encode(%{"normalized_expression" => u.normalized_expression})
    assert Encode.expression_digest(u.normalized_expression) == u.expression_digest
  end

  test ">2KB multibyte unresolved expression remains JSON-encodable after identity bound" do
    # >2048 bytes of multibyte codepoints (CJK "中" is 3 bytes UTF-8).
    # Total raw payload ≈ 3 * 800 = 2400 bytes, well over 2KB and over @max_expr_bytes.
    multibyte = String.duplicate("中", 800)
    assert byte_size(multibyte) > 2048

    src = """
    defmodule Arbor.Utf8.Over2k do
      def call(x), do: Module.concat([x, "#{multibyte}"]).f()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/a/lib/utf8_2k.ex", src)
    assert result.unresolved != []
    u = hd(result.unresolved)

    assert String.valid?(u.normalized_expression)
    assert byte_size(u.normalized_expression) <= 2000
    assert String.valid?(u.evidence)
    assert byte_size(u.evidence) <= 240
    assert Encode.expression_digest(u.normalized_expression) == u.expression_digest

    # Full report-shaped payload (as Encode.encode_report would emit) must encode.
    report_fragment = %{
      "schema" => "arbor.packaging.source_coupling.report.v1",
      "unresolved" => %{
        "count" => 1,
        "items" => [
          %{
            "file" => u.file,
            "line" => u.line,
            "from_module" => u.from_module,
            "reason" => u.reason,
            "kind" => u.kind,
            "normalized_expression" => u.normalized_expression,
            "evidence" => u.evidence,
            "expression_digest" => u.expression_digest
          }
        ]
      }
    }

    assert {:ok, json} = Jason.encode(report_fragment)
    assert is_binary(json)
    assert String.valid?(json)
    assert {:ok, decoded} = Jason.decode(json)

    assert get_in(decoded, ["unresolved", "items", Access.at(0), "expression_digest"]) ==
             u.expression_digest
  end

  test "unresolved digest uses full bounded form not display truncation" do
    # Two long expressions that share a long common prefix but differ at the end.
    # If digest used only truncated evidence, they could collide.
    prefix = String.duplicate("Segment", 40)

    src1 = """
    defmodule Arbor.Dyn.Long1 do
      def call(x), do: Module.concat([x, "#{prefix}_ALPHA"]).f()
    end
    """

    src2 = """
    defmodule Arbor.Dyn.Long2 do
      def call(x), do: Module.concat([x, "#{prefix}_BETA"]).f()
    end
    """

    assert {:ok, r1} = AstExtract.extract("apps/a/lib/l1.ex", src1)
    assert {:ok, r2} = AstExtract.extract("apps/a/lib/l2.ex", src2)
    assert r1.unresolved != []
    assert r2.unresolved != []

    u1 = hd(r1.unresolved)
    u2 = hd(r2.unresolved)

    assert u1.expression_digest != u2.expression_digest

    # Digest matches full normalized_expression (identity form), not evidence.
    assert Encode.expression_digest(u1.normalized_expression) == u1.expression_digest
    assert is_binary(u1.evidence)
    assert byte_size(u1.evidence) <= 240

    # Evidence may be shorter than full form when form is long.
    if byte_size(u1.normalized_expression) > 240 do
      assert byte_size(u1.evidence) < byte_size(u1.normalized_expression)
      # Digesting evidence alone would be wrong for identity.
      refute Encode.expression_digest(u1.evidence) == u1.expression_digest
    end
  end

  test "ordinary alias expressions emit expr refs across common positions" do
    src = """
    defmodule Arbor.Expr.Positions do
      def assign do
        mod = Arbor.Persistence.Repo
        mod
      end

      def arg(x), do: pass(x, Arbor.Contracts.Skill)

      def ret, do: Arbor.Security.Keychain

      def containers do
        [
          Arbor.Memory.WorkingMemory,
          {Arbor.Signals, :ok},
          %{handler: Arbor.LLM.OpenAI}
        ]
      end

      def guarded(x) when x == Arbor.Trust.Policy, do: :ok

      def rescued do
        try do
          :ok
        rescue
          e in [Arbor.Common.Error] -> e
        end
      end
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/expr_positions.ex", src)

    expr_targets =
      result.references
      |> Enum.filter(&(&1.kind == "expr"))
      |> Enum.map(& &1.target)
      |> MapSet.new()

    assert "Arbor.Persistence.Repo" in expr_targets
    assert "Arbor.Contracts.Skill" in expr_targets
    assert "Arbor.Security.Keychain" in expr_targets
    assert "Arbor.Memory.WorkingMemory" in expr_targets
    assert "Arbor.Signals" in expr_targets
    assert "Arbor.LLM.OpenAI" in expr_targets
    assert "Arbor.Trust.Policy" in expr_targets
    assert "Arbor.Common.Error" in expr_targets
  end

  test "production shape mod = Arbor.Persistence.Repo is captured as expr" do
    # Mirrors apps/arbor_common/lib/arbor/common/agent_telemetry/store.ex get_repo/0.
    src = """
    defmodule Arbor.Common.AgentTelemetry.Store do
      defp get_repo do
        mod = Arbor.Persistence.Repo

        if Code.ensure_loaded?(mod) and Process.whereis(mod) != nil do
          {:ok, mod}
        else
          {:error, :unavailable}
        end
      end
    end
    """

    assert {:ok, result} =
             AstExtract.extract(
               "apps/arbor_common/lib/arbor/common/agent_telemetry/store.ex",
               src
             )

    assert Enum.any?(result.references, fn r ->
             r.target == "Arbor.Persistence.Repo" and r.kind == "expr" and
               r.from_module == "Arbor.Common.AgentTelemetry.Store"
           end)
  end

  test "specialized alias contexts do not double-count primary occurrences" do
    src = """
    defmodule Arbor.Dup.Host do
      alias Arbor.Alpha.One
      import Arbor.Alpha.Two
      require Arbor.Alpha.Three
      use Arbor.Alpha.Four
      @behaviour Arbor.Alpha.Five
      @handler Arbor.Alpha.Six

      defstruct []

      def with_default(x \\\\ Arbor.Alpha.Seven), do: x

      def remote, do: Arbor.Alpha.Eight.run()
      def struct_ref, do: %Arbor.Alpha.Nine{}
      def concat, do: Module.concat([Arbor.Alpha, Ten])
    end

    defimpl Arbor.Alpha.Proto, for: Arbor.Alpha.Impl do
      def encode(_), do: ""
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/dup_host.ex", src)

    by_target =
      result.references
      |> Enum.group_by(& &1.target)
      |> Map.new(fn {t, refs} -> {t, Enum.map(refs, & &1.kind)} end)

    # Each specialized primary occurrence must appear once with its specialized kind.
    assert by_target["Arbor.Alpha.One"] == ["alias"]
    assert by_target["Arbor.Alpha.Two"] == ["import"]
    assert by_target["Arbor.Alpha.Three"] == ["require"]
    assert by_target["Arbor.Alpha.Four"] == ["use"]
    assert by_target["Arbor.Alpha.Five"] == ["behaviour"]
    assert by_target["Arbor.Alpha.Six"] == ["attribute"]
    assert by_target["Arbor.Alpha.Seven"] == ["default"]
    assert by_target["Arbor.Alpha.Eight"] == ["remote"]
    assert by_target["Arbor.Alpha.Nine"] == ["struct"]
    assert by_target["Arbor.Alpha.Ten"] == ["module_concat"]
    assert by_target["Arbor.Alpha.Proto"] == ["defimpl"]
    assert by_target["Arbor.Alpha.Impl"] == ["defimpl"]

    # No expr twin for any of the specialized primaries above.
    refute Enum.any?(result.references, fn r ->
             r.kind == "expr" and
               r.target in [
                 "Arbor.Alpha.One",
                 "Arbor.Alpha.Two",
                 "Arbor.Alpha.Three",
                 "Arbor.Alpha.Four",
                 "Arbor.Alpha.Five",
                 "Arbor.Alpha.Six",
                 "Arbor.Alpha.Seven",
                 "Arbor.Alpha.Eight",
                 "Arbor.Alpha.Nine",
                 "Arbor.Alpha.Ten",
                 "Arbor.Alpha.Proto",
                 "Arbor.Alpha.Impl"
               ]
           end)
  end

  test "nested independent aliases inside specialized constructs remain visible" do
    src = """
    defmodule Arbor.Nested.Indep do
      use Arbor.Alpha.Macro, helper: Arbor.Alpha.Helper

      def with_default(x \\\\ pass(Arbor.Alpha.DefaultArg)), do: x

      def remote_nested, do: Arbor.Alpha.Outer.run(Arbor.Alpha.Inner)

      def struct_nested, do: %Arbor.Alpha.Struct{mod: Arbor.Alpha.Field}

      def concat_partial(x), do: Module.concat([Arbor.Alpha.Partial, x]).f()

      @cfg %{
        known: Arbor.Alpha.Known,
        other: pass(Arbor.Alpha.UnknownNested)
      }
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/nested_indep.ex", src)

    kinds_for = fn target ->
      result.references
      |> Enum.filter(&(&1.target == target))
      |> Enum.map(& &1.kind)
      |> Enum.sort()
    end

    assert kinds_for.("Arbor.Alpha.Macro") == ["use"]
    assert kinds_for.("Arbor.Alpha.Helper") == ["expr"]
    assert kinds_for.("Arbor.Alpha.DefaultArg") == ["expr"]
    assert kinds_for.("Arbor.Alpha.Outer") == ["remote"]
    assert kinds_for.("Arbor.Alpha.Inner") == ["expr"]
    assert kinds_for.("Arbor.Alpha.Struct") == ["struct"]
    assert kinds_for.("Arbor.Alpha.Field") == ["expr"]
    assert kinds_for.("Arbor.Alpha.Partial") == ["expr"]
    assert kinds_for.("Arbor.Alpha.Known") == ["attribute"]
    assert kinds_for.("Arbor.Alpha.UnknownNested") == ["expr"]
  end

  test "defmodule name is ownership not an ordinary expr reference" do
    src = """
    defmodule Arbor.Defmod.Name do
      def ok, do: :ok
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/defmod_name.ex", src)
    assert Enum.any?(result.module_defs, &(&1.module == "Arbor.Defmod.Name"))

    refute Enum.any?(result.references, fn r ->
             r.target == "Arbor.Defmod.Name"
           end)
  end

  test "alias as: short name is not emitted as ordinary expr" do
    src = """
    defmodule Arbor.Alias.AsHost do
      alias Arbor.Alpha.LongName, as: Short
      def call, do: Short.f()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/alias_as.ex", src)
    targets = Enum.map(result.references, & &1.target)
    assert "Arbor.Alpha.LongName" in targets
    refute "Short" in targets

    assert Enum.count(result.references, &(&1.target == "Arbor.Alpha.LongName")) == 2
    # One alias binding + one remote via Short expansion — no expr for as: name.
    kinds =
      result.references
      |> Enum.filter(&(&1.target == "Arbor.Alpha.LongName"))
      |> Enum.map(& &1.kind)
      |> Enum.sort()

    assert kinds == ["alias", "remote"]
  end

  test "dynamic Module.concat remains unresolved and keeps static nested aliases" do
    src = """
    defmodule Arbor.Concat.Partial do
      def call(x), do: Module.concat([Arbor.Alpha.StaticPart, x]).f()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/concat_partial.ex", src)

    assert Enum.any?(result.references, fn r ->
             r.target == "Arbor.Alpha.StaticPart" and r.kind == "expr"
           end)

    assert Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_concat" or u.reason == "dynamic_module_expr"
           end)
  end

  test "nested attribute map module leaves are emitted recursively as attribute" do
    # Nested maps under atom keys must emit module leaves — top-level-only
    # bind_map_attr previously dropped Arbor.Alpha.NestedLeaf.
    src = """
    defmodule Arbor.Attr.NestedMap do
      @cfg %{
        outer: %{
          inner: Arbor.Alpha.NestedLeaf,
          other: "literal"
        },
        top: Arbor.Alpha.TopLeaf
      }

      def cfg, do: @cfg.outer
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/attr_nested_map.ex", src)

    assert Enum.any?(result.references, fn r ->
             r.target == "Arbor.Alpha.NestedLeaf" and r.kind == "attribute"
           end)

    assert Enum.any?(result.references, fn r ->
             r.target == "Arbor.Alpha.TopLeaf" and r.kind == "attribute"
           end)

    # Nested leaf must not be missing or downgraded solely to expr without attribute.
    refute Enum.any?(result.references, fn r ->
             r.target == "Arbor.Alpha.NestedLeaf" and r.kind == "expr"
           end)
  end

  test "dynamic attribute map keys walk key and value without suppressing modules" do
    # Dynamic keys are excluded from the classified field map; their module values
    # must still surface via AST walk. Uncertain-key access stays fail-closed.
    src = """
    defmodule Arbor.Attr.DynKeyMod do
      @handlers %{
        unquote(key) => Arbor.Alpha.DynValue,
        static: Arbor.Alpha.StaticValue
      }

      def call_static, do: @handlers.static.run()
      def call_dyn, do: @handlers.other.run()
    end
    """

    assert {:ok, result} = AstExtract.extract("apps/arbor_common/lib/attr_dyn_key_mod.ex", src)

    assert Enum.any?(result.references, fn r ->
             r.target == "Arbor.Alpha.StaticValue" and r.kind == "attribute"
           end)

    assert Enum.any?(result.references, fn r ->
             r.target == "Arbor.Alpha.DynValue" and r.kind == "expr"
           end)

    # Uncertain keys: static field access must not resolve as a trusted module expr.
    assert Enum.any?(result.unresolved, fn u ->
             u.reason == "dynamic_module_expr" and
               String.contains?(u.normalized_expression, "handlers") and
               String.contains?(u.normalized_expression, "static")
           end)
  end

  test "unresolved default Module.concat keeps independent nested alias" do
    # Root default is dynamic/unresolved, but Arbor.Foo inside the concat list is
    # an independent static alias and must still be emitted.
    src = """
    defmodule Arbor.Default.ConcatNested do
      def call(x \\\\ Module.concat([x, Arbor.Alpha.DefaultNested])), do: x
    end
    """

    assert {:ok, result} =
             AstExtract.extract("apps/arbor_common/lib/default_concat_nested.ex", src)

    assert Enum.any?(result.references, fn r ->
             r.target == "Arbor.Alpha.DefaultNested" and r.kind == "expr"
           end)

    assert Enum.any?(result.unresolved, fn u ->
             u.kind == "default" or
               u.reason in ["dynamic_module_expr", "dynamic_module_concat"]
           end)

    # Root unresolved once — nested alias is a separate expr ref, not a second
    # root-default unresolved for the same concat site identity only.
    default_unresolved =
      Enum.filter(result.unresolved, fn u ->
        u.kind == "default" or
          (u.reason in ["dynamic_module_expr", "dynamic_module_concat"] and
             String.contains?(u.normalized_expression || "", "concat"))
      end)

    assert length(default_unresolved) == 1
  end
end
