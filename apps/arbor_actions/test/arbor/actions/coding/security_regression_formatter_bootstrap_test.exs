defmodule Arbor.Actions.Coding.SecurityRegression.FormatterBootstrapTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Coding.SecurityRegression.Core
  alias Arbor.Actions.Coding.SecurityRegression.Formatter

  @moduletag :fast
  @moduletag :security_regression

  @schema_project_mix_file "apps/arbor_persistence/mix.exs"
  @schema_bootstrap_args ["-r", "Arbor.Persistence.Repo", "--quiet"]
  @selected_test "test/selected_test.exs"

  test "security regression: generated runner create-migrate-test order is executable" do
    fixture = run_fixture()

    assert fixture.outcome.result == :ok

    assert fixture.outcome.calls == [
             {:rerun, "ecto.create", @schema_bootstrap_args},
             {:rerun, "ecto.migrate", @schema_bootstrap_args},
             {:run, "test", Formatter.mix_test_flags(fixture.module_name) ++ [@selected_test]}
           ]

    assert fixture.outcome.schema_dir?
    assert fixture.outcome.schema_path == Path.join(fixture.home, ".arbor")
  end

  test "security regression: generated runner fails closed on ecto.create raise" do
    fixture = run_fixture(raise_on: "ecto.create")

    assert fixture.outcome.result == {:error, :schema_bootstrap_failed}
    assert fixture.outcome.calls == [{:rerun, "ecto.create", @schema_bootstrap_args}]
    assert_setup_failure_artifact(fixture.artifact)
  end

  test "security regression: generated runner classifies migrate failure without running tests" do
    fixture = run_fixture(raise_on: "ecto.migrate")

    assert fixture.outcome.result == {:error, :schema_bootstrap_failed}

    assert fixture.outcome.calls == [
             {:rerun, "ecto.create", @schema_bootstrap_args},
             {:rerun, "ecto.migrate", @schema_bootstrap_args}
           ]

    assert_setup_failure_artifact(fixture.artifact)
  end

  test "security regression: generated runner classifies mkdir failure without running tests" do
    fixture = run_fixture(schema_home_as_file: true)

    assert fixture.outcome.result == {:error, :schema_bootstrap_failed}
    assert fixture.outcome.calls == []
    assert_setup_failure_artifact(fixture.artifact)
  end

  test "security regression: generated runner skips schema bootstrap without persistence app" do
    fixture = run_fixture(schema_project?: false)

    assert fixture.outcome.result == :ok

    assert fixture.outcome.calls == [
             {:run, "test", Formatter.mix_test_flags(fixture.module_name) ++ [@selected_test]}
           ]

    refute fixture.outcome.schema_dir?
    assert fixture.outcome.schema_path == Path.join(fixture.home, ".arbor")
  end

  defp run_fixture(opts \\ []) do
    tmp_dir = unique_tmp_dir!()
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    home = Path.join(tmp_dir, "home")
    File.mkdir!(home)

    if Keyword.get(opts, :schema_project?, true) do
      plant_persistence_mix!(tmp_dir)
    end

    if Keyword.get(opts, :schema_home_as_file, false) do
      File.write!(Path.join(home, ".arbor"), "not-a-directory")
    end

    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :upper)
    module_name = "ArborSecurityRegressionFormatter.M" <> suffix
    formatter_module = String.to_atom("Elixir." <> module_name)
    fake_module = ArborSecurityRegressionFakeMixTask
    artifact = Path.join(tmp_dir, "result.etf")
    outcome_path = Path.join(tmp_dir, "outcome.etf")
    script_path = Path.join(tmp_dir, "bootstrap_runner.exs")
    raise_on = Keyword.get(opts, :raise_on)

    assert {:ok, source} = Formatter.runner_source(module_name)
    formatter_ast = extract_defmodule_ast!(source)

    fake_ast =
      quote do
        defmodule unquote(fake_module) do
          @raise_on unquote(raise_on)
          @calls_key {__MODULE__, :calls}

          def start do
            Process.put(@calls_key, [])
            :ok
          end

          def calls do
            @calls_key
            |> Process.get([])
            |> Enum.reverse()
          end

          def rerun(name, args) do
            record(:rerun, name, args)
            maybe_raise(name)
            :ok
          end

          def run(name, args) do
            record(:run, name, args)
            maybe_raise(name)
            :ok
          end

          defp record(fun, name, args) do
            Process.put(@calls_key, [{fun, name, args} | Process.get(@calls_key, [])])
          end

          defp maybe_raise(name) do
            if name == @raise_on, do: raise("#{name} exploded")
          end
        end
      end

    exercise_ast =
      quote do
        :ok = unquote(fake_module).start()

        :ok =
          apply(unquote(formatter_module), :configure_mix_task_module, [unquote(fake_module)])

        :ok = apply(unquote(formatter_module), :store_artifact_path!, [unquote(artifact)])

        result =
          apply(unquote(formatter_module), :prepare_schema_and_run_tests!, [
            [unquote(@selected_test)]
          ])

        outcome = %{
          calls: unquote(fake_module).calls(),
          result: result,
          schema_dir?: File.dir?(Path.expand("~/.arbor")),
          schema_path: Path.expand("~/.arbor")
        }

        File.write!(
          unquote(outcome_path),
          :erlang.term_to_binary(outcome, [:deterministic]),
          [:binary]
        )
      end

    script =
      {:__block__, [], [fake_ast, formatter_ast, exercise_ast]}
      |> Macro.to_string()

    File.write!(script_path, script)

    elixir = System.find_executable("elixir") || flunk("pinned elixir executable unavailable")

    {output, exit_code} =
      System.cmd(elixir, [script_path],
        cd: tmp_dir,
        env: [{"HOME", home}],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "fresh-HOME bootstrap runner failed (exit #{exit_code}): " <>
             String.slice(output, 0, 4_096)

    assert {:ok, outcome_bytes} = File.read(outcome_path)
    outcome = :erlang.binary_to_term(outcome_bytes, [:safe])

    %{
      artifact: artifact,
      home: home,
      module_name: module_name,
      outcome: outcome,
      tmp_dir: tmp_dir
    }
  end

  defp assert_setup_failure_artifact(artifact) do
    assert {:ok, bytes} = File.read(artifact)
    assert {:ok, counts} = Core.validate_artifact(:erlang.binary_to_term(bytes, [:safe]))
    assert counts["setup_failures"] == 1
    assert counts["executed"] == 0
    assert counts["suite_started"] == false

    candidate = Core.completed_leg(2, false, counts, %{})
    assert Core.candidate_gate(candidate) == {:error, "candidate_setup_failed"}
  end

  defp unique_tmp_dir! do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "sr-bootstrap-" <> suffix)
    File.mkdir!(path)
    path
  end

  defp plant_persistence_mix!(tmp_dir) do
    mix_file = Path.join(tmp_dir, @schema_project_mix_file)
    File.mkdir_p!(Path.dirname(mix_file))
    File.write!(mix_file, "defmodule Arbor.Persistence.MixProject do\nend\n")
  end

  defp extract_defmodule_ast!(source) when is_binary(source) do
    assert {:ok, ast} = Code.string_to_quoted(source)

    module_ast =
      case ast do
        {:__block__, _meta, forms} when is_list(forms) ->
          Enum.find(forms, &match?({:defmodule, _, _}, &1))

        {:defmodule, _, _} = form ->
          form

        _other ->
          nil
      end

    assert is_tuple(module_ast)
    module_ast
  end
end
