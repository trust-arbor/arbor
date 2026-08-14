defmodule Arbor.Kernel.ConfigCompatCompileEnvTest do
  use ExUnit.Case, async: false

  require Arbor.Kernel.ConfigCompat
  alias Arbor.Kernel.ConfigCompat

  @moduletag :fast

  @owners [:arbor_contracts, :arbor_common, :arbor_signals, :arbor_monitor]
  @probe :k2_compat_compile_probe
  @nested_root :k2_compat_compile_nested
  @conflict :k2_compat_compile_conflict
  @start_children_owners [:arbor_common, :arbor_signals, :arbor_monitor]

  setup do
    snapshot = snapshot_state()
    on_exit(fn -> restore_state(snapshot) end)
    :ok
  end

  test "compile_env expansion records both apps unconditionally with owner-prefixed kernel path" do
    ast =
      quote do
        ConfigCompat.compile_env(:arbor_common, :k2_probe, :d)
      end

    assert_unconditional_dual_compile_env(
      Macro.expand_once(ast, __ENV__),
      :arbor_common,
      :k2_probe
    )
  end

  test "compile_env nested-path expansion prefixes only the kernel read" do
    ast =
      quote do
        ConfigCompat.compile_env(:arbor_common, [:nested, :path], :default)
      end

    assert_unconditional_dual_compile_env(
      Macro.expand_once(ast, __ENV__),
      :arbor_common,
      [:nested, :path]
    )
  end

  test "compile_env! expansion records both apps unconditionally with owner-prefixed kernel path" do
    ast =
      quote do
        ConfigCompat.compile_env!(:arbor_signals, :k2_probe)
      end

    assert_unconditional_dual_compile_env(
      Macro.expand_once(ast, __ENV__),
      :arbor_signals,
      :k2_probe
    )
  end

  test "compiled compile_env values match the runtime precedence table" do
    delete_kernel(:arbor_common, @probe)
    Application.delete_env(:arbor_common, @probe)
    assert compile_probe(:neither, :arbor_common, @probe, :caller_default) == :caller_default

    Application.put_env(:arbor_common, @probe, :legacy_only)
    assert compile_probe(:legacy, :arbor_common, @probe, :caller_default) == :legacy_only

    put_kernel(:arbor_common, @probe, :kernel_only)
    Application.delete_env(:arbor_common, @probe)
    assert compile_probe(:kernel, :arbor_common, @probe, :caller_default) == :kernel_only

    put_kernel(:arbor_common, @probe, :same)
    Application.put_env(:arbor_common, @probe, :same)
    assert compile_probe(:equal, :arbor_common, @probe, :caller_default) == :same
  end

  test "compiled compile_env nested path walks the owner-prefixed kernel path" do
    put_kernel(:arbor_signals, @nested_root, path: :from_kernel)
    Application.delete_env(:arbor_signals, @nested_root)

    assert compile_path_probe(:kernel_path, :arbor_signals, [@nested_root, :path], :missing) ==
             :from_kernel

    delete_kernel(:arbor_signals, @nested_root)
    Application.put_env(:arbor_signals, @nested_root, path: :from_legacy)

    assert compile_path_probe(:legacy_path, :arbor_signals, [@nested_root, :path], :missing) ==
             :from_legacy

    put_kernel(:arbor_signals, @nested_root, path: :shared)
    Application.put_env(:arbor_signals, @nested_root, path: :shared)

    assert compile_path_probe(:equal_path, :arbor_signals, [@nested_root, :path], :missing) ==
             :shared

    delete_kernel(:arbor_signals, @nested_root)
    Application.delete_env(:arbor_signals, @nested_root)

    assert compile_path_probe(
             :neither_path,
             :arbor_signals,
             [@nested_root, :path],
             :caller_default
           ) ==
             :caller_default
  end

  test "compile_env conflict raises and still expanded both reads" do
    ast =
      quote do
        ConfigCompat.compile_env(:arbor_common, :k2_conflict, :unused)
      end

    assert_unconditional_dual_compile_env(
      Macro.expand_once(ast, __ENV__),
      :arbor_common,
      :k2_conflict
    )

    put_kernel(:arbor_common, @conflict, :kernel_value)
    Application.put_env(:arbor_common, @conflict, :legacy_value)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      compile_probe(:conflict, :arbor_common, @conflict, :unused)
    end
  end

  test "compile_env rejects an empty path at expansion time" do
    ast =
      quote do
        ConfigCompat.compile_env(:arbor_common, [], :default)
      end

    assert_raise ArgumentError, ~r/non-empty atom path/, fn ->
      Macro.expand_once(ast, __ENV__)
    end
  end

  test "compile_env rejects concrete non-atom paths at expansion time" do
    binary =
      quote do
        ConfigCompat.compile_env(:arbor_common, "bad", :default)
      end

    number =
      quote do
        ConfigCompat.compile_env(:arbor_common, 1, :default)
      end

    tuple =
      quote do
        ConfigCompat.compile_env(:arbor_common, {:bad, :path, :value}, :default)
      end

    assert_raise ArgumentError, ~r/non-empty atom path/, fn ->
      Macro.expand_once(binary, __ENV__)
    end

    assert_raise ArgumentError, ~r/non-empty atom path/, fn ->
      Macro.expand_once(number, __ENV__)
    end

    assert_raise ArgumentError, ~r/non-empty atom path/, fn ->
      Macro.expand_once(tuple, __ENV__)
    end
  end

  test "compile_env preserves dynamic quoted paths for controlled caller expansion" do
    dynamic_path = quote(do: runtime_key_path())

    ast =
      quote do
        ConfigCompat.compile_env(:arbor_common, unquote(dynamic_path), :default)
      end

    expanded = Macro.expand_once(ast, __ENV__)

    assert [
             {:arbor_kernel, kernel_path, _kernel_default},
             {:arbor_common, ^dynamic_path, _legacy_default}
           ] = application_compile_env_calls(expanded)

    assert {{:., _, [receiver, :kernel_path]}, _, [:arbor_common, ^dynamic_path]} = kernel_path
    assert resolve_compile_receiver?(receiver)
  end

  test "compiled compile_env reads map namespaces and rejects malformed ones" do
    Application.delete_env(:arbor_common, @probe)
    Application.put_env(:arbor_kernel, :common, %{@probe => :from_map})
    assert compile_probe(:map_ns, :arbor_common, @probe, :missing) == :from_map

    Application.put_env(:arbor_kernel, :common, %{@probe => nil})
    assert compile_probe(:map_nil, :arbor_common, @probe, :missing) == nil

    Application.put_env(:arbor_kernel, :common, "bad-ns")

    assert_raise ArgumentError, ~r/malformed :arbor_kernel namespace/, fn ->
      compile_probe(:bad_ns, :arbor_common, @probe, :unused)
    end

    Application.put_env(:arbor_kernel, :common, nil)

    assert_raise ArgumentError, ~r/nil_namespace/, fn ->
      compile_probe(:nil_ns, :arbor_common, @probe, :unused)
    end
  end

  test "compiled start_children values stay owner-scoped" do
    Enum.each(@start_children_owners, fn owner ->
      Application.delete_env(owner, :start_children)
      Application.delete_env(:arbor_kernel, ConfigCompat.kernel_namespace(owner))
      Application.delete_env(:arbor_kernel, owner)
    end)

    Application.put_env(:arbor_kernel, :common, start_children: :common_compiled)
    Application.put_env(:arbor_kernel, :signals, start_children: :signals_compiled)
    Application.put_env(:arbor_kernel, :monitor, start_children: :monitor_compiled)

    assert compile_probe(:sc_common, :arbor_common, :start_children, :missing) == :common_compiled

    assert compile_probe(:sc_signals, :arbor_signals, :start_children, :missing) ==
             :signals_compiled

    assert compile_probe(:sc_monitor, :arbor_monitor, :start_children, :missing) ==
             :monitor_compiled

    Application.put_env(:arbor_signals, :start_children, :signals_legacy)

    assert_raise ArgumentError, ~r/rejects unequal dual values/, fn ->
      compile_probe(:sc_conflict, :arbor_signals, :start_children, :unused)
    end

    assert compile_probe(:sc_common_after, :arbor_common, :start_children, :missing) ==
             :common_compiled
  end

  test "compiled compile_env! returns the configured value from the module body" do
    put_kernel(:arbor_monitor, @probe, :present)
    Application.delete_env(:arbor_monitor, @probe)
    assert compile_bang_probe(:present, :arbor_monitor, @probe) == :present
  end

  test "compiled compile_env! raises when neither side is configured" do
    delete_kernel(:arbor_monitor, @probe)
    Application.delete_env(:arbor_monitor, @probe)

    assert_raise ArgumentError, ~r/could not fetch/, fn ->
      compile_bang_probe(:missing, :arbor_monitor, @probe)
    end
  end

  defp compile_probe(tag, owner, key, default) do
    mod = Module.concat(__MODULE__, :"Probe#{tag}#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(mod) do
          require Arbor.Kernel.ConfigCompat

          @value Arbor.Kernel.ConfigCompat.compile_env(
                   unquote(owner),
                   unquote(key),
                   unquote(default)
                 )

          def value, do: @value
        end
      end

    [{^mod, _bytecode}] = Code.compile_quoted(quoted)
    apply(mod, :value, [])
  end

  defp compile_path_probe(tag, owner, path, default) do
    mod = Module.concat(__MODULE__, :"PathProbe#{tag}#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(mod) do
          require Arbor.Kernel.ConfigCompat

          @value Arbor.Kernel.ConfigCompat.compile_env(
                   unquote(owner),
                   unquote(path),
                   unquote(default)
                 )

          def value, do: @value
        end
      end

    [{^mod, _bytecode}] = Code.compile_quoted(quoted)
    apply(mod, :value, [])
  end

  defp compile_bang_probe(tag, owner, key) do
    mod = Module.concat(__MODULE__, :"BangProbe#{tag}#{System.unique_integer([:positive])}")

    quoted =
      quote do
        defmodule unquote(mod) do
          require Arbor.Kernel.ConfigCompat

          @value Arbor.Kernel.ConfigCompat.compile_env!(unquote(owner), unquote(key))
          def value, do: @value
        end
      end

    [{^mod, _bytecode}] = Code.compile_quoted(quoted)
    apply(mod, :value, [])
  end

  defp assert_unconditional_dual_compile_env(expanded, owner, expected_legacy) do
    assert resolve_compile_call?(expanded)
    refute compile_env_under_conditional?(expanded)

    assert [
             {:arbor_kernel, kernel_path, _kernel_default},
             {^owner, legacy_path, _legacy_default}
           ] = application_compile_env_calls(expanded)

    namespace = ConfigCompat.kernel_namespace(owner)
    assert kernel_path == [namespace | List.wrap(expected_legacy)]
    assert legacy_path == expected_legacy
    refute hd(kernel_path) in @owners
  end

  defp resolve_compile_call?({{:., _, [receiver, :resolve_compile]}, _, args})
       when is_list(args) and length(args) == 5 do
    resolve_compile_receiver?(receiver)
  end

  defp resolve_compile_call?(_), do: false

  defp resolve_compile_receiver?({:__aliases__, _, parts}) when is_list(parts) do
    List.last(parts) == :ConfigCompat
  end

  defp resolve_compile_receiver?(Arbor.Kernel.ConfigCompat), do: true
  defp resolve_compile_receiver?(_), do: false

  defp application_compile_env_calls(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [receiver, :compile_env]}, _, [app, path | rest]} = node, acc ->
          if application_receiver?(receiver) do
            {node, [{app, path, List.first(rest)} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp application_receiver?({:__aliases__, _, [:Application]}), do: true
  defp application_receiver?({:__aliases__, _, [:"Elixir", :Application]}), do: true
  defp application_receiver?(Application), do: true
  defp application_receiver?(_), do: false

  defp compile_env_under_conditional?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {form, _, args} = node, acc when form in [:case, :if, :cond] and is_list(args) ->
          {node, acc or application_compile_env_calls(args) != []}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp put_kernel(owner, key, value) do
    namespace = ConfigCompat.kernel_namespace(owner)

    current =
      case Application.fetch_env(:arbor_kernel, namespace) do
        {:ok, config} when is_list(config) -> config
        _ -> []
      end

    Application.put_env(:arbor_kernel, namespace, Keyword.put(current, key, value))
  end

  defp delete_kernel(owner, key) do
    namespace = ConfigCompat.kernel_namespace(owner)

    case Application.fetch_env(:arbor_kernel, namespace) do
      {:ok, config} when is_list(config) ->
        next = Keyword.delete(config, key)

        if next == [] do
          Application.delete_env(:arbor_kernel, namespace)
        else
          Application.put_env(:arbor_kernel, namespace, next)
        end

      _ ->
        :ok
    end
  end

  defp snapshot_state do
    namespaces = Enum.map(@owners, &ConfigCompat.kernel_namespace/1)

    kernel =
      Enum.map(namespaces ++ @owners, fn key ->
        {{:arbor_kernel, key}, Application.fetch_env(:arbor_kernel, key)}
      end)

    keys = [@probe, @nested_root, @conflict, :start_children]

    legacy =
      for owner <- @owners, key <- keys do
        {{owner, key}, Application.fetch_env(owner, key)}
      end

    kernel ++ legacy
  end

  defp restore_state(snapshot) do
    Enum.each(snapshot, fn
      {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
      {{app, key}, :error} -> Application.delete_env(app, key)
    end)
  end
end
