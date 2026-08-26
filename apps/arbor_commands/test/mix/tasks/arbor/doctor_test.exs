defmodule Mix.Tasks.Arbor.DoctorTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Mix.Tasks.Arbor.Doctor

  # `fallback_model/2` is the LLMDB-unavailable fallback path. It must NEVER return
  # a hard-coded model id (those go stale — cf. the retired trinity-large-preview)
  # and must respect local-first setups. The layering is: configured default (for
  # the default provider) → live local discovery → honest nil.
  describe "fallback_model/2 — no hard-coded models, local-first" do
    test "uses the configured default model for the configured default provider" do
      deps = %{
        default_provider: :openrouter,
        default_model: "openai/gpt-oss-120b:free",
        discover: fn _ -> [] end
      }

      assert Doctor.fallback_model(:openrouter, deps) == "openai/gpt-oss-120b:free"
    end

    test "discovers a live local model for a non-default provider (Ollama/LM Studio)" do
      deps = %{
        default_provider: :openrouter,
        default_model: "openai/gpt-oss-120b:free",
        discover: fn
          :ollama -> ["llama3.1:8b", "qwen2.5:7b"]
          _ -> []
        end
      }

      assert Doctor.fallback_model(:ollama, deps) == "llama3.1:8b"
    end

    test "returns nil (honest) when nothing is configured or discoverable — not a guess" do
      # The old behavior here was a hard-coded `claude-sonnet-...`. The regression
      # guard: an undiscoverable provider must NOT yield a fabricated model string.
      deps = %{default_provider: :ollama, default_model: nil, discover: fn _ -> [] end}

      assert Doctor.fallback_model(:anthropic, deps) == nil
    end

    test "prefers the configured default over discovery when this is the default provider" do
      deps = %{
        default_provider: :ollama,
        default_model: "granite4.1:3b",
        discover: fn _ -> ["something-else:latest"] end
      }

      assert Doctor.fallback_model(:ollama, deps) == "granite4.1:3b"
    end

    test "falls through to discovery when the configured default model is missing" do
      deps = %{
        default_provider: :ollama,
        default_model: nil,
        discover: fn :ollama -> ["qwen2.5:7b"] end
      }

      assert Doctor.fallback_model(:ollama, deps) == "qwen2.5:7b"
    end
  end

  # Merged from the former test/mix/tasks/arbor.doctor_test.exs, which defined a
  # second `Mix.Tasks.Arbor.DoctorTest` at a non-canonical path — two files with
  # the same module name shadowed each other (one file's tests silently didn't
  # run). Consolidated here under the canonical path.

  describe "configure priority" do
    test "prefers OpenRouter, local, and ACP before paid APIs" do
      keys = Enum.map(Doctor.provider_priority(), fn {catalog_key, _, _} -> catalog_key end)
      free_or_local = ["openrouter", "ollama", "lm_studio", "acp", "opencode_zen"]
      paid = ["anthropic", "openai", "google", "xai"]

      assert keys -- paid == free_or_local

      last_free =
        keys
        |> Enum.with_index()
        |> Enum.filter(fn {key, _} -> key in free_or_local end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.max()

      first_paid =
        keys
        |> Enum.with_index()
        |> Enum.filter(fn {key, _} -> key in paid end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.min()

      assert last_free < first_paid
      assert hd(keys) == "openrouter"
    end
  end

  describe "module availability" do
    test "task module is loaded" do
      assert {:module, Mix.Tasks.Arbor.Doctor} = Code.ensure_loaded(Mix.Tasks.Arbor.Doctor)
    end
  end

  describe "validation vs runtimes flags" do
    test "--validation is a known strict option and does not collide with --runtimes" do
      {opts, rest, invalid} =
        OptionParser.parse(["--validation", "--json"], strict: Doctor.cli_strict())

      assert invalid == []
      assert rest == []
      assert opts[:validation] == true
      assert opts[:json] == true

      {runtime_opts, _, runtime_invalid} =
        OptionParser.parse(["--runtimes"], strict: Doctor.cli_strict())

      assert runtime_invalid == []
      assert runtime_opts[:runtimes] == true
      refute runtime_opts[:validation]

      {both, _, both_invalid} =
        OptionParser.parse(["--validation", "--runtimes"], strict: Doctor.cli_strict())

      assert both_invalid == []
      assert both[:validation] == true
      assert both[:runtimes] == true
    end

    test "--validation cannot be combined with --runtimes" do
      assert_raise Mix.Error, ~r/--validation cannot be combined with --runtimes/, fn ->
        Doctor.run(["--validation", "--runtimes"])
      end
    end

    test "unknown flags still raise" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        Doctor.run(["--not-a-doctor-flag"])
      end
    end
  end

  describe "option parsing" do
    test "parses --refresh flag" do
      {opts, _, _} =
        OptionParser.parse(["--refresh"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:refresh] == true
    end

    test "parses --json flag" do
      {opts, _, _} =
        OptionParser.parse(["--json"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:json] == true
    end

    test "parses --verbose flag" do
      {opts, _, _} =
        OptionParser.parse(["--verbose"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:verbose] == true
    end

    test "parses --configure flag" do
      {opts, _, _} =
        OptionParser.parse(["--configure"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:configure] == true
    end

    test "handles multiple flags" do
      {opts, _, _} =
        OptionParser.parse(["--verbose", "--json"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:verbose] == true
      assert opts[:json] == true
    end
  end

  describe "provider catalog dependency" do
    test "ProviderCatalog module exists" do
      assert Code.ensure_loaded?(Arbor.LLM.ProviderCatalog)
    end
  end

  describe "runtime-axis flags (Phase 4+ arbor.doctor extension)" do
    @all_switches [
      refresh: :boolean,
      json: :boolean,
      verbose: :boolean,
      configure: :boolean,
      runtimes: :boolean,
      model: :string,
      fallback: :keep,
      runtime: :string
    ]

    test "--runtimes is a boolean flag" do
      {opts, _, _} = OptionParser.parse(["--runtimes"], switches: @all_switches)
      assert opts[:runtimes] == true
    end

    test "--model takes a string argument" do
      {opts, _, _} =
        OptionParser.parse(["--model", "claude-opus-4-6"], switches: @all_switches)

      assert opts[:model] == "claude-opus-4-6"
    end

    test "--fallback can be repeated; each value collected separately" do
      {opts, _, _} =
        OptionParser.parse(
          [
            "--fallback",
            "runtime=acp",
            "--fallback",
            "model=claude-sonnet-4-6,provider=anthropic"
          ],
          switches: @all_switches
        )

      values = for {:fallback, v} <- opts, do: v
      assert values == ["runtime=acp", "model=claude-sonnet-4-6,provider=anthropic"]
    end

    test "--runtime takes a string argument" do
      {opts, _, _} =
        OptionParser.parse(["--runtime", "acp"], switches: @all_switches)

      assert opts[:runtime] == "acp"
    end

    test "all new flags compose with each other" do
      {opts, _, _} =
        OptionParser.parse(
          [
            "--model",
            "claude-opus-4-6",
            "--runtime",
            "arbor",
            "--fallback",
            "runtime=acp",
            "--json"
          ],
          switches: @all_switches
        )

      assert opts[:model] == "claude-opus-4-6"
      assert opts[:runtime] == "arbor"
      assert opts[:json] == true
      assert [_] = for({:fallback, v} <- opts, do: v)
    end

    test "--refresh-models is a boolean flag" do
      switches = Keyword.put(@all_switches, :refresh_models, :boolean)
      {opts, _, _} = OptionParser.parse(["--refresh-models"], switches: switches)
      assert opts[:refresh_models] == true
    end

    test "--refresh-models composes with --json" do
      switches = Keyword.put(@all_switches, :refresh_models, :boolean)

      {opts, _, _} =
        OptionParser.parse(["--refresh-models", "--json"], switches: switches)

      assert opts[:refresh_models] == true
      assert opts[:json] == true
    end
  end

  describe "write_env_key/3 — export-prefixed assignments" do
    setup do
      path = Path.join(System.tmp_dir!(), "doctor-env-#{System.unique_integer([:positive])}.env")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "updates an export-prefixed key in place instead of appending a duplicate",
         %{path: path} do
      # config/runtime.exs strips a leading "export " when loading .env, so both
      # forms are live. Matching only the bare form appended a SECOND assignment
      # and left the file with two entries for one key.
      File.write!(path, "export ARBOR_DEFAULT_PROVIDER=openrouter\n")

      Doctor.write_env_key(path, "ARBOR_DEFAULT_PROVIDER", "opencode_zen")

      content = File.read!(path)

      assignments =
        for line <- String.split(content, "\n"),
            String.contains?(line, "ARBOR_DEFAULT_PROVIDER="),
            do: String.trim(line)

      assert length(assignments) == 1, "expected one assignment, got: #{inspect(assignments)}"
      assert hd(assignments) == "export ARBOR_DEFAULT_PROVIDER=opencode_zen"
    end

    test "updates a bare key in place and keeps it bare", %{path: path} do
      File.write!(path, "ARBOR_DEFAULT_PROVIDER=openrouter\n")

      Doctor.write_env_key(path, "ARBOR_DEFAULT_PROVIDER", "opencode_zen")

      assert File.read!(path) =~ "ARBOR_DEFAULT_PROVIDER=opencode_zen"
      refute File.read!(path) =~ "openrouter"
      refute File.read!(path) =~ "export ARBOR_DEFAULT_PROVIDER"
    end

    test "appends when the key is genuinely absent", %{path: path} do
      File.write!(path, "export SOMETHING_ELSE=1\n")

      Doctor.write_env_key(path, "ARBOR_DEFAULT_PROVIDER", "opencode_zen")

      content = File.read!(path)
      assert content =~ "SOMETHING_ELSE=1"
      assert content =~ "ARBOR_DEFAULT_PROVIDER=opencode_zen"
    end

    test "ignores a commented assignment and appends a live one", %{path: path} do
      File.write!(path, "#export ARBOR_DEFAULT_PROVIDER=old\n")

      Doctor.write_env_key(path, "ARBOR_DEFAULT_PROVIDER", "opencode_zen")

      content = File.read!(path)
      assert content =~ "#export ARBOR_DEFAULT_PROVIDER=old"
      assert content =~ "\nARBOR_DEFAULT_PROVIDER=opencode_zen"
    end
  end
end
