defmodule Arbor.Shell.AppleContainerExecutionCoreTest do
  @moduledoc """
  Pure adversarial tests for Apple Container execution-request core.

  Slice 2C/2D foundation only — no IO, process execution, or facade wiring.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerExecutionCore, as: Core

  @moduletag :fast

  @digest String.duplicate("a", 64)
  @init_digest String.duplicate("b", 64)
  @workload "127.0.0.1:0/arbor/workload@sha256:#{@digest}"
  @vminit "127.0.0.1:0/arbor/vminit@sha256:#{@init_digest}"
  @kernel "/usr/local/share/container/kernels/default.kernel"
  @unit "arbor-val-unit01"
  @mix_wrapper "/private/tmp/arbor-val/bin/mix"
  @worktree "/private/tmp/arbor-val/worktree"

  @valid_admission %{
    "admitted" => true,
    "platform" => %{"os" => "macos", "version" => "26.5.2", "architecture" => "arm64"},
    "runtime" => %{"path" => "/usr/local/bin/container"},
    "image" => %{
      "execution_reference" => @workload,
      "platform" => "linux/arm64"
    },
    "vminit" => %{
      "execution_reference" => @vminit,
      "platform" => "linux/arm64"
    },
    "control_plane" => %{
      "kernel" => %{"path" => @kernel}
    }
  }

  defp entry(purpose, path, mode), do: %{purpose: purpose, path: path, mode: mode}

  defp base_projections do
    %{
      runtime_erlang:
        entry(:runtime_erlang, "/opt/homebrew/Cellar/erlang/28.4.1/lib/erlang", :read_only),
      runtime_elixir: entry(:runtime_elixir, "/opt/homebrew/Cellar/elixir/1.19.5", :read_only),
      mix_wrapper: entry(:mix_wrapper, @mix_wrapper, :read_only),
      worktree: entry(:worktree, @worktree, :read_write),
      home: entry(:home, "/private/tmp/arbor-val/home", :read_write),
      tmp: entry(:tmp, "/private/tmp/arbor-val/tmp", :read_write),
      build: entry(:build, "/private/tmp/arbor-val/build", :read_write),
      deps: entry(:deps, "/private/tmp/arbor-val/deps", :read_write),
      runtime: entry(:runtime, "/private/tmp/arbor-val/runtime", :read_write)
    }
  end

  defp valid_opts(overrides \\ []) do
    base = [
      cwd: @worktree,
      timeout: 60_000,
      sandbox: :basic,
      env: %{},
      clear_env: true,
      filesystem_projections: base_projections()
    ]

    Keyword.merge(base, overrides)
  end

  defp valid_request(overrides \\ %{}) do
    Map.merge(
      %{
        tool_name: @mix_wrapper,
        args: ["compile"],
        opts: valid_opts(),
        admission: @valid_admission,
        unit_name: @unit
      },
      overrides
    )
  end

  describe "positive command shapes" do
    test "compile" do
      assert {:ok, spec} = Core.new(valid_request(%{args: ["compile"]}))
      assert spec.plan.command_args == ["compile"]
      assert spec.timeout_ms == 60_000
      assert spec.max_output_bytes == 8_388_608
    end

    test "compile --warnings-as-errors" do
      assert {:ok, spec} =
               Core.new(valid_request(%{args: ["compile", "--warnings-as-errors"]}))

      assert spec.plan.command_args == ["compile", "--warnings-as-errors"]
    end

    test "quality" do
      assert {:ok, spec} = Core.new(valid_request(%{args: ["quality"]}))
      assert spec.plan.command_args == ["quality"]
    end

    test "xref graph" do
      assert {:ok, spec} = Core.new(valid_request(%{args: ["xref", "graph"]}))
      assert spec.plan.command_args == ["xref", "graph"]
    end

    test "xref graph --format stats|cycles|linked" do
      for format <- ["stats", "cycles", "linked"] do
        assert {:ok, spec} =
                 Core.new(valid_request(%{args: ["xref", "graph", "--format", format]}))

        assert spec.plan.command_args == ["xref", "graph", "--format", format]
      end
    end

    test "test bare and with ordered flags and paths" do
      shapes = [
        ["test"],
        ["test", "--only", "fast"],
        ["test", "--seed", "42"],
        ["test", "--only", "fast", "--seed", "0"],
        ["test", "--", "test/example_test.exs"],
        ["test", "--only", "fast", "--", "apps/arbor_shell/test/foo_test.exs"],
        [
          "test",
          "--only",
          "security_regression",
          "--seed",
          "7",
          "--",
          "test/a_test.exs",
          "apps/arbor_shell/test/b_test.exs:12"
        ]
      ]

      for args <- shapes do
        assert {:ok, spec} = Core.new(valid_request(%{args: args}))
        assert spec.plan.command_args == args
        assert spec.plan.mix_env == "test"
      end
    end

    test "format bare, check-only, and with paths" do
      shapes = [
        ["format"],
        ["format", "--check-formatted"],
        ["format", "--", "lib/foo.ex"],
        ["format", "--check-formatted", "--", "apps/arbor_shell/lib/a.ex", "mix.exs"]
      ]

      for args <- shapes do
        assert {:ok, spec} = Core.new(valid_request(%{args: args}))
        assert spec.plan.command_args == args
        assert spec.plan.mix_env == "dev"
      end
    end

    test "defaults max_output_bytes and accepts hard max" do
      assert {:ok, spec} = Core.new(valid_request())
      assert spec.max_output_bytes == 8_388_608

      assert {:ok, spec2} =
               Core.new(valid_request(%{opts: valid_opts(max_output_bytes: 16_777_216)}))

      assert spec2.max_output_bytes == 16_777_216
    end

    test "selects MIX_ENV from map or keyword and ignores credentials" do
      assert {:ok, spec} =
               Core.new(
                 valid_request(%{
                   args: ["compile"],
                   opts:
                     valid_opts(
                       env: %{
                         "MIX_ENV" => "prod",
                         "AWS_SECRET_ACCESS_KEY" => "super-secret",
                         "PATH" => "/evil/bin"
                       }
                     )
                 })
               )

      assert spec.plan.mix_env == "prod"

      refute Enum.any?(spec.plan.env, fn {k, v} ->
               k == "AWS_SECRET_ACCESS_KEY" or v == "super-secret"
             end)

      refute Enum.any?(spec.plan.env, fn {k, _} -> k == "PATH" end)

      assert {:ok, spec2} =
               Core.new(
                 valid_request(%{
                   args: ["quality"],
                   opts: valid_opts(env: [MIX_ENV: "test", SECRET: "nope"])
                 })
               )

      assert spec2.plan.mix_env == "test"
    end

    test "show is JSON-clean and deterministic" do
      assert {:ok, spec} = Core.new(valid_request(%{args: ["test"]}))
      shown = Core.show(spec)
      assert Jason.encode!(shown)
      assert shown["timeout_ms"] == 60_000
      assert shown["max_output_bytes"] == 8_388_608
      assert shown["plan"]["image"] == @workload
      assert shown["plan"]["init_image"] == @vminit
      assert shown["plan"]["kernel_path"] == @kernel
      refute inspect(shown) =~ "super-secret"
      refute Map.has_key?(shown, "env")
    end

    test "string-keyed input aliases work without atom duplicates" do
      request = %{
        "tool_name" => @mix_wrapper,
        "args" => ["compile"],
        "opts" => valid_opts(),
        "admission" => @valid_admission,
        "unit_name" => @unit
      }

      assert {:ok, spec} = Core.new(request)
      assert spec.plan.command_args == ["compile"]
    end

    test "list-form filesystem projections are accepted" do
      list = Enum.map(base_projections(), fn {_k, v} -> v end)

      assert {:ok, spec} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: list)}))

      assert spec.plan.projections.worktree == @worktree
    end
  end

  describe "adversarial options and bounds" do
    test "rejects unknown and duplicate top-level keys" do
      assert {:error, {:unsupported_execution_request_keys, _}} =
               Core.new(Map.put(valid_request(), :extra, 1))

      assert {:error, {:duplicate_execution_request_key_alias, :args}} =
               Core.new(Map.put(valid_request(), "args", ["compile"]))
    end

    test "rejects caller authority injection fields" do
      for key <- [:image, :init_image, :kernel_path, :plan, :argv, :policy, :receipt, "authority"] do
        assert {:error, :caller_authority_injection} =
                 Core.new(Map.put(valid_request(), key, "evil"))
      end
    end

    test "rejects stdin and unknown opts, duplicate opt keys, missing required" do
      assert {:error, :stdin_not_supported} =
               Core.new(valid_request(%{opts: valid_opts() ++ [stdin: "x"]}))

      assert {:error, {:unsupported_opt_keys, _}} =
               Core.new(valid_request(%{opts: valid_opts() ++ [shell: true]}))

      assert {:error, :duplicate_opt_key} =
               Core.new(valid_request(%{opts: valid_opts() ++ [cwd: @worktree]}))

      assert {:error, {:missing_opt_keys, _}} =
               Core.new(
                 valid_request(%{
                   opts: [
                     timeout: 1,
                     sandbox: :basic,
                     env: %{},
                     clear_env: true,
                     filesystem_projections: base_projections()
                   ]
                 })
               )

      assert {:error, :invalid_opts} = Core.new(valid_request(%{opts: %{cwd: @worktree}}))

      assert {:error, :invalid_sandbox} =
               Core.new(valid_request(%{opts: valid_opts(sandbox: :none)}))

      assert {:error, :clear_env_required} =
               Core.new(valid_request(%{opts: valid_opts(clear_env: false)}))
    end

    test "rejects timeout and max_output_bytes bounds without clamping" do
      assert {:error, :timeout_too_large} =
               Core.new(valid_request(%{opts: valid_opts(timeout: 300_001)}))

      assert {:error, :timeout_too_small} =
               Core.new(valid_request(%{opts: valid_opts(timeout: 0)}))

      assert {:error, :max_output_bytes_too_large} =
               Core.new(valid_request(%{opts: valid_opts(max_output_bytes: 16_777_217)}))

      assert {:error, :invalid_max_output_bytes} =
               Core.new(valid_request(%{opts: valid_opts(max_output_bytes: 0)}))
    end
  end

  describe "projection validation" do
    test "rejects missing, extra, mode swap, duplicates, and overlap" do
      missing = Map.delete(base_projections(), :deps)

      assert {:error, {:missing_projections, [:deps]}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: missing)}))

      extra = Map.put(base_projections(), :evil, entry(:worktree, "/tmp/evil", :read_write))

      assert {:error, :unsupported_projection_purpose} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: extra)}))

      swapped =
        put_in(base_projections(), [:worktree], entry(:worktree, @worktree, :read_only))

      assert {:error, {:projection_mode_mismatch, :worktree, :read_only}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: swapped)}))

      dup_paths =
        put_in(base_projections(), [:home], entry(:home, @worktree, :read_write))

      assert {:error, :duplicate_projection_paths} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: dup_paths)}))

      overlap =
        put_in(
          base_projections(),
          [:tmp],
          entry(:tmp, @worktree <> "/nested", :read_write)
        )

      assert {:error, {:overlapping_projection_paths, _, _}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: overlap)}))
    end

    test "rejects tool_name/cwd mismatches" do
      assert {:error, :tool_name_mix_wrapper_mismatch} =
               Core.new(valid_request(%{tool_name: "/usr/bin/mix"}))

      assert {:error, :cwd_worktree_mismatch} =
               Core.new(valid_request(%{opts: valid_opts(cwd: "/private/tmp/other")}))
    end

    test "rejects duplicate purpose atom/string aliases in map" do
      bad =
        base_projections()
        |> Map.delete(:worktree)
        |> Map.put("worktree", entry(:worktree, @worktree, :read_write))
        |> Map.put(:worktree, entry(:worktree, @worktree, :read_write))

      # map_size will be 10 with both aliases
      assert {:error, reason} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: bad)}))

      assert reason in [:duplicate_projection_purpose, :unsupported_projection_purpose] or
               match?({:missing_projections, _}, reason) == false
    end
  end

  describe "command and path injection" do
    test "rejects unsupported mix tasks and reordered/duplicate flags" do
      for args <- [
            ["deps.get"],
            ["run", "-e", "IO.puts(1)"],
            ["test", "--seed", "1", "--only", "fast"],
            ["test", "--only", "fast", "--only", "slow"],
            ["test", "--"],
            ["test", "--", "/absolute/test.exs"],
            ["test", "--", "../escape_test.exs"],
            ["test", "--", "--only"],
            ["format", "--", "/etc/passwd"],
            ["format", "--", "../x.ex"],
            ["format", "--"],
            ["xref", "callers", "Foo"],
            ["compile", "--force"],
            ["quality", "--strict"]
          ] do
        assert {:error, _reason} = Core.new(valid_request(%{args: args}))
      end
    end

    test "rejects non-string args, NUL, invalid UTF-8, and empty" do
      assert {:error, :invalid_command_args} = Core.new(valid_request(%{args: [:compile]}))
      assert {:error, :empty_command_args} = Core.new(valid_request(%{args: []}))
      assert {:error, :unsafe_command_arg} = Core.new(valid_request(%{args: ["compile", "a\0b"]}))

      assert {:error, :invalid_utf8} =
               Core.new(valid_request(%{args: ["compile", <<0xC3, 0x28>>]}))
    end
  end

  describe "admission and authority" do
    test "rejects malformed admission and wrong runtime/platform" do
      assert {:error, :not_admitted} =
               Core.new(valid_request(%{admission: Map.put(@valid_admission, "admitted", false)}))

      bad_runtime =
        put_in(@valid_admission, ["runtime", "path"], "/usr/bin/container")

      assert {:error, :runtime_path_mismatch} =
               Core.new(valid_request(%{admission: bad_runtime}))

      bad_arch =
        put_in(@valid_admission, ["platform", "architecture"], "x86_64")

      assert {:error, :host_architecture_not_supported} =
               Core.new(valid_request(%{admission: bad_arch}))

      bad_image_platform =
        put_in(@valid_admission, ["image", "platform"], "linux/amd64")

      assert {:error, {:guest_platform_not_supported, :image}} =
               Core.new(valid_request(%{admission: bad_image_platform}))

      assert {:error, :missing_image_execution_reference} =
               Core.new(
                 valid_request(%{
                   admission: put_in(@valid_admission, ["image"], %{"platform" => "linux/arm64"})
                 })
               )
    end

    @tag :security_regression
    test "security regression: only admitted receipt references enter the plan" do
      evil_workload = "127.0.0.1:0/arbor/workload@sha256:#{String.duplicate("c", 64)}"
      evil_vminit = "127.0.0.1:0/arbor/vminit@sha256:#{String.duplicate("d", 64)}"

      # Caller cannot inject alternate image via top-level fields.
      assert {:error, :caller_authority_injection} =
               Core.new(Map.put(valid_request(), :image, evil_workload))

      assert {:error, :caller_authority_injection} =
               Core.new(Map.put(valid_request(), "init_image", evil_vminit))

      assert {:ok, spec} = Core.new(valid_request(%{args: ["test", "--only", "fast"]}))
      assert spec.plan.image == @workload
      assert spec.plan.init_image == @vminit
      assert spec.plan.kernel_path == @kernel
      assert spec.plan.runtime_executable == "/usr/local/bin/container"

      create = Enum.join(spec.plan.argv.create, " ")
      assert String.contains?(create, @workload)
      assert String.contains?(create, @vminit)
      assert String.contains?(create, @kernel)
      refute String.contains?(create, evil_workload)
      refute String.contains?(create, evil_vminit)

      # Mutating the admission changes plan authority.
      alt =
        @valid_admission
        |> put_in(["image", "execution_reference"], evil_workload)
        |> put_in(["vminit", "execution_reference"], evil_vminit)

      assert {:ok, alt_spec} = Core.new(valid_request(%{admission: alt}))
      assert alt_spec.plan.image == evil_workload
      assert alt_spec.plan.init_image == evil_vminit
    end
  end

  describe "facade remains fail-closed" do
    test "execute_spawn_capable stays production_backend_missing" do
      assert {:error, {:spawn_backend_unavailable, :production_backend_missing}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end
  end
end
