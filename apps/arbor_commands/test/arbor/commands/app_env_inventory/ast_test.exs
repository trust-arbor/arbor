defmodule Arbor.Commands.AppEnvInventory.AstTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.AppEnvInventory.Ast

  @moduletag :fast

  test "classifies literal Application env calls and config blocks" do
    {:ok, lib} =
      Ast.extract("apps/arbor_common/lib/arbor/common/config.ex", """
      defmodule Sample.Lib do
        def read, do: Application.get_env(:arbor_common, :skill_dirs, [])
        def fetch, do: Application.fetch_env(:arbor_signals, :authorizer)
        def bang, do: Application.fetch_env!(:arbor_monitor, :enabled_skills)
        def put, do: Application.put_env(:arbor_common, :x, 1)
        def delete, do: Application.delete_env(:arbor_common, :x)
        def compile, do: Application.compile_env(:arbor_common, :y, :d)
      end
      """)

    assert Enum.map(lib, & &1["form"]) == [
             "get_env",
             "fetch_env",
             "fetch_env!",
             "put_env",
             "delete_env",
             "compile_env"
           ]

    assert Enum.all?(lib, &(&1["class"] == "production"))
    assert Enum.all?(lib, &(&1["trust"] == "literal"))

    {:ok, cfg} =
      Ast.extract("config/config.exs", """
      import Config
      config :arbor_common, :hands, []
      config :arbor_signals, authorizer: :x
      """)

    assert Enum.map(cfg, & &1["form"]) == ["config", "config"]
    assert Enum.all?(cfg, &(&1["class"] == "config_block"))
  end

  test "resolves aliases, imports, module attributes, and local binds" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/x.ex", """
      defmodule Sample.Resolved do
        alias Application, as: App
        @otp_app :arbor_common

        def via_alias, do: App.get_env(:arbor_signals, :authorizer)

        def via_attr, do: Application.get_env(@otp_app, :k)

        def via_bind do
          app = :arbor_monitor
          Application.get_env(app, :k)
        end
      end
      """)

    assert Enum.map(findings, &{&1["trust"], &1["legacy_app"], &1["form"]}) == [
             {"literal", "arbor_signals", "get_env"},
             {"resolved", "arbor_common", "get_env"},
             {"resolved", "arbor_monitor", "get_env"}
           ]
  end

  test "does not flag generic helpers without retired-key evidence" do
    {:ok, findings} =
      Ast.extract("apps/foo/test/support/helpers.ex", """
      defmodule Sample.Helpers do
        defp restore_env(app, key, nil), do: Application.delete_env(app, key)
        defp restore_env(app, key, value), do: Application.put_env(app, key, value)
        defp read(app, key), do: Application.get_env(app, key)
        def via_mod(mod), do: mod.get_env(:arbor_persistence, :repo)
        def compile(otp_app), do: Application.compile_env(unquote(otp_app), :k, :d)
      end
      """)

    assert findings == []
  end

  test "untrusted when a dynamic app expression contains a retired atom" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/dyn.ex", """
      defmodule Sample.Dyn do
        def read(other), do: Application.get_env(hd([:arbor_common, other]), :k)
      end
      """)

    assert [%{"trust" => "untrusted", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "counts :application.set_env with a literal retired atom" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/erlang.ex", """
      defmodule Sample.Erlang do
        def write, do: :application.set_env(:arbor_common, :k, 1)
      end
      """)

    assert [%{"form" => "put_env", "legacy_app" => "arbor_common", "trust" => "literal"}] =
             findings
  end

  test "does not count comments, moduledocs, or ConfigCompat calls" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/docs.ex", """
      defmodule Sample.Docs do
        @moduledoc \"\"\"
        Example:

            config :arbor_common, :trust_zones, %{}
            Application.get_env(:arbor_common, :skill_dirs)
        \"\"\"

        # Application.get_env(:arbor_common, :skill_dirs)

        def via_compat, do: Arbor.Kernel.ConfigCompat.get_env(:arbor_common, :k, nil)
      end
      """)

    assert findings == []
  end

  test "classifies test paths as test_support" do
    {:ok, findings} =
      Ast.extract("apps/arbor_signals/test/arbor/signals/bus_test.exs", """
      Application.put_env(:arbor_signals, :authorizer, :x)
      """)

    assert [%{"class" => "test_support", "form" => "put_env"}] = findings
  end

  test "malformed source fails closed" do
    assert {:error, {:parse_error, "apps/foo/lib/bad.ex", _}} =
             Ast.extract("apps/foo/lib/bad.ex", "defmodule Oops do\n")
  end

  test "does not leak local app binds across sibling functions" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/leak.ex", """
      defmodule Sample.FnLeak do
        def write do
          app = :arbor_common
          Application.put_env(app, :k, 1)
        end

        def read, do: Application.get_env(app, :k)
      end
      """)

    assert [%{"trust" => "resolved", "legacy_app" => "arbor_common", "form" => "put_env"}] =
             findings
  end

  test "does not leak local app binds across sibling branches" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/branch.ex", """
      defmodule Sample.BranchLeak do
        def read(flag) do
          if flag do
            app = :arbor_common
            Application.get_env(app, :k)
          else
            Application.get_env(app, :k)
          end
        end
      end
      """)

    assert [%{"trust" => "resolved", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "same-function binds remain visible inside an inner branch" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/inner.ex", """
      defmodule Sample.InnerBind do
        def read do
          app = :arbor_monitor
          if true do
            Application.get_env(app, :k)
          end
        end
      end
      """)

    assert [%{"trust" => "resolved", "legacy_app" => "arbor_monitor", "form" => "get_env"}] =
             findings
  end

  test "unknown dynamic receivers are not Application or Config calls" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/dyn_recv.ex", """
      defmodule Sample.DynRecv do
        def via_mod(mod), do: mod.get_env(:arbor_common, :k)
        def via_cfg(mod), do: mod.config(:arbor_signals, :authorizer)
      end
      """)

    assert findings == []
  end

  test "cyclic module attributes do not recurse without a bound" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/cycle.ex", """
      defmodule Sample.Cycle do
        @a @b
        @b @a
        def read, do: Application.get_env(@a, :k)
      end
      """)

    assert findings == []
  end

  test "default alias binds the final segment, not Elixir.Application" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/shadow_app.ex", """
      defmodule Sample.ShadowApp do
        alias Foo.Application

        def read, do: Application.get_env(:arbor_common, :k)
        def fetch, do: Application.fetch_env(:arbor_signals, :authorizer)
      end
      """)

    assert findings == []
  end

  test "explicit as: Application does not classify as Elixir.Application" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/as_alias.ex", """
      defmodule Sample.AsAlias do
        alias Foo.Bar, as: Application

        def read, do: Application.get_env(:arbor_common, :k)
      end
      """)

    assert findings == []
  end

  test "non-literal __MODULE__ aliases do not crash or invent Application receivers" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/mod_alias.ex", """
      defmodule Sample.ModAlias do
        alias __MODULE__.Child
        alias __MODULE__.NodeRestartCAS

        def read, do: Child.get_env(:arbor_common, :k)
        def cas, do: NodeRestartCAS.get_env(:arbor_signals, :k)
      end
      """)

    assert findings == []
  end

  test "does not leak function-local aliases or imports to sibling functions" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/alias_leak.ex", """
      defmodule Sample.AliasLeak do
        def write do
          alias Application, as: App
          import Application
          App.put_env(:arbor_common, :k, 1)
          put_env(:arbor_signals, :k, 1)
        end

        def read do
          App.get_env(:arbor_monitor, :k)
          get_env(:arbor_contracts, :k)
        end
      end
      """)

    assert Enum.map(findings, &{&1["form"], &1["legacy_app"]}) == [
             {"put_env", "arbor_common"},
             {"put_env", "arbor_signals"}
           ]
  end

  test "does not leak branch-local aliases or imports to sibling branches" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/branch_alias.ex", """
      defmodule Sample.BranchAlias do
        def read(flag) do
          if flag do
            alias Application, as: App
            import Application
            App.get_env(:arbor_common, :k)
          else
            App.get_env(:arbor_signals, :k)
            get_env(:arbor_monitor, :k)
          end
        end
      end
      """)

    assert [%{"trust" => "literal", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "bounded retired-atom collection does not raise on a large dynamic expression" do
    extras = Enum.map_join(1..200, ", ", &":k#{&1}")

    {:ok, findings} =
      Ast.extract("apps/foo/lib/huge.ex", """
      defmodule Sample.Huge do
        def read, do: Application.get_env(hd([:arbor_common, #{extras}]), :k)
      end
      """)

    assert [%{"trust" => "untrusted", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "deep dynamic retired-atom collection stays bounded" do
    nested = Enum.reduce(1..30, ":arbor_common", fn _, acc -> "[#{acc}]" end)

    assert {:ok, findings} =
             Ast.extract("apps/foo/lib/deep.ex", """
             defmodule Sample.Deep do
               def read, do: Application.get_env(hd(#{nested}), :k)
             end
             """)

    assert [%{"trust" => "untrusted", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "walks module-attribute right-hand sides for retired env calls" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/attr_rhs.ex", """
      defmodule Sample.AttrRHS do
        @ignored Application.get_env(:arbor_common, :k)
        def read, do: :ok
      end
      """)

    assert [%{"trust" => "literal", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "unknown rebind shadows a prior resolved owner" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/rebind.ex", """
      defmodule Sample.Rebind do
        def read do
          app = :arbor_common
          app = unknown()
          Application.get_env(app, :k)
        end
      end
      """)

    assert findings == []
  end

  test "assignment RHS sees the prior binding before LHS shadow" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/assign_rhs.ex", """
      defmodule Sample.AssignRHS do
        def read do
          app = :arbor_common
          app = Application.get_env(app, :k)
        end
      end
      """)

    assert [%{"trust" => "resolved", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "named functions do not inherit module-body locals but do inherit aliases" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/mod_local.ex", """
      defmodule Sample.ModLocal do
        app = :arbor_common
        alias Application, as: App

        def read, do: Application.get_env(app, :k)
        def via_alias, do: App.get_env(:arbor_signals, :k)
      end
      """)

    assert [%{"trust" => "literal", "legacy_app" => "arbor_signals", "form" => "get_env"}] =
             findings
  end

  test "pattern variables shadow prior owner binds in every lexical block" do
    {:ok, fn_findings} =
      Ast.extract("apps/foo/lib/fn_pat.ex", """
      defmodule Sample.FnPat do
        def read do
          app = :arbor_common
          fn app -> Application.get_env(app, :k) end
        end
      end
      """)

    {:ok, case_findings} =
      Ast.extract("apps/foo/lib/case_pat.ex", """
      defmodule Sample.CasePat do
        def read(x) do
          app = :arbor_common
          case x do
            app -> Application.get_env(app, :k)
          end
        end
      end
      """)

    {:ok, with_findings} =
      Ast.extract("apps/foo/lib/with_pat.ex", """
      defmodule Sample.WithPat do
        def read(x) do
          app = :arbor_monitor
          with {:ok, app} <- x do
            Application.get_env(app, :k)
          else
            _ -> Application.get_env(app, :k)
          end
        end
      end
      """)

    {:ok, for_findings} =
      Ast.extract("apps/foo/lib/for_pat.ex", """
      defmodule Sample.ForPat do
        def read(list) do
          app = :arbor_common
          for app <- list do
            Application.get_env(app, :k)
          end
        end
      end
      """)

    {:ok, try_findings} =
      Ast.extract("apps/foo/lib/try_pat.ex", """
      defmodule Sample.TryPat do
        def read do
          app = :arbor_common
          try do
            Application.get_env(app, :k)
          rescue
            app -> Application.get_env(app, :k)
          catch
            app -> Application.get_env(app, :k)
          after
            Application.get_env(app, :k)
          end
        end
      end
      """)

    {:ok, receive_findings} =
      Ast.extract("apps/foo/lib/recv_pat.ex", """
      defmodule Sample.RecvPat do
        def read do
          app = :arbor_common
          receive do
            app -> Application.get_env(app, :k)
          after
            0 -> Application.get_env(app, :k)
          end
        end
      end
      """)

    assert fn_findings == []
    assert case_findings == []
    assert for_findings == []

    assert Enum.map(with_findings, & &1["legacy_app"]) == ["arbor_monitor"]
    assert length(try_findings) == 2
    assert Enum.all?(try_findings, &(&1["legacy_app"] == "arbor_common"))
    assert length(receive_findings) == 1
    assert hd(receive_findings)["legacy_app"] == "arbor_common"
  end

  test "cond clauses do not leak sibling binds" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/cond.ex", """
      defmodule Sample.Cond do
        def read do
          app = :arbor_common
          cond do
            false ->
              app = :arbor_signals
              Application.get_env(app, :k)

            true ->
              Application.get_env(app, :k)
          end
        end
      end
      """)

    assert Enum.map(findings, &{&1["trust"], &1["legacy_app"]}) == [
             {"resolved", "arbor_signals"},
             {"resolved", "arbor_common"}
           ]
  end

  test "pins retain the outer owner binding" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/pin.ex", """
      defmodule Sample.Pin do
        def read(x) do
          app = :arbor_common
          case x do
            {:ok, ^app} -> Application.get_env(app, :k)
          end
        end
      end
      """)

    assert [%{"trust" => "resolved", "legacy_app" => "arbor_common", "form" => "get_env"}] =
             findings
  end

  test "quote-local aliases and binds do not leak" do
    {:ok, findings} =
      Ast.extract("apps/foo/lib/quote.ex", """
      defmodule Sample.Quote do
        def read do
          quote do
            alias Application, as: App
            app = :arbor_common
          end

          App.get_env(:arbor_signals, :k)
          Application.get_env(app, :k)
        end
      end
      """)

    assert findings == []
  end

  test "__MODULE__ and grouped aliases shadow Application even when unresolved" do
    {:ok, mod_findings} =
      Ast.extract("apps/foo/lib/mod_app.ex", """
      defmodule Sample.ModApp do
        alias __MODULE__.Application

        def read, do: Application.get_env(:arbor_common, :k)
      end
      """)

    {:ok, grouped} =
      Ast.extract("apps/foo/lib/grouped.ex", """
      defmodule Sample.Grouped do
        alias Foo.{Application, Config}

        def read, do: Application.get_env(:arbor_common, :k)
        def cfg, do: Config.config(:arbor_signals, :authorizer)
      end
      """)

    {:ok, as_mod} =
      Ast.extract("apps/foo/lib/as_mod.ex", """
      defmodule Sample.AsMod do
        alias __MODULE__, as: Application

        def read, do: Application.get_env(:arbor_common, :k)
      end
      """)

    assert mod_findings == []
    assert grouped == []
    assert as_mod == []
  end
end
