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

  # Mirror Arbor.Actions.Mix.projections_for_resource/2 exact wire shape:
  # string-keyed entry maps inside a grouped envelope with revision.
  defp actions_entry(path, mode, purpose) do
    %{
      "path" => path,
      "mode" => Atom.to_string(mode),
      "purpose" => Atom.to_string(purpose)
    }
  end

  defp base_projections(revision \\ "candidate") do
    %{
      read_only: [
        actions_entry(
          "/opt/homebrew/Cellar/erlang/28.4.1/lib/erlang",
          :read_only,
          :runtime_erlang
        ),
        actions_entry("/opt/homebrew/Cellar/elixir/1.19.5", :read_only, :runtime_elixir),
        actions_entry(@mix_wrapper, :read_only, :mix_wrapper)
      ],
      read_write: [
        actions_entry(@worktree, :read_write, :worktree),
        actions_entry("/private/tmp/arbor-val/home", :read_write, :home),
        actions_entry("/private/tmp/arbor-val/tmp", :read_write, :tmp),
        actions_entry("/private/tmp/arbor-val/build", :read_write, :build),
        actions_entry("/private/tmp/arbor-val/deps", :read_write, :deps)
      ],
      revision: revision
    }
  end

  defp put_group_entry(projections, group, purpose, entry) do
    list = Map.fetch!(projections, group)

    updated =
      Enum.map(list, fn existing ->
        if existing["purpose"] == Atom.to_string(purpose) or
             existing[:purpose] == purpose do
          entry
        else
          existing
        end
      end)

    Map.put(projections, group, updated)
  end

  defp delete_group_entry(projections, group, purpose) do
    list =
      projections
      |> Map.fetch!(group)
      |> Enum.reject(fn existing ->
        existing["purpose"] == Atom.to_string(purpose) or existing[:purpose] == purpose
      end)

    Map.put(projections, group, list)
  end

  # Retired flat purpose-map shape (pre-envelope) plus runtime parent purpose.
  defp legacy_flat_projections do
    %{
      runtime_erlang: %{
        purpose: :runtime_erlang,
        path: "/opt/homebrew/Cellar/erlang/28.4.1/lib/erlang",
        mode: :read_only
      },
      runtime_elixir: %{
        purpose: :runtime_elixir,
        path: "/opt/homebrew/Cellar/elixir/1.19.5",
        mode: :read_only
      },
      mix_wrapper: %{purpose: :mix_wrapper, path: @mix_wrapper, mode: :read_only},
      worktree: %{purpose: :worktree, path: @worktree, mode: :read_write},
      home: %{purpose: :home, path: "/private/tmp/arbor-val/home", mode: :read_write},
      tmp: %{purpose: :tmp, path: "/private/tmp/arbor-val/tmp", mode: :read_write},
      build: %{purpose: :build, path: "/private/tmp/arbor-val/build", mode: :read_write},
      deps: %{purpose: :deps, path: "/private/tmp/arbor-val/deps", mode: :read_write},
      runtime: %{purpose: :runtime, path: "/private/tmp/arbor-val/runtime", mode: :read_write}
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

    test "admits Actions grouped envelope with string entry keys and revision" do
      for revision <- ["candidate", "base"] do
        projections = base_projections(revision)

        assert {:ok, spec} =
                 Core.new(valid_request(%{opts: valid_opts(filesystem_projections: projections)}))

        assert spec.plan.projections.worktree == @worktree
        assert spec.plan.projections.mix_wrapper == @mix_wrapper
        refute Map.has_key?(spec.plan.projections, :runtime)
      end
    end

    test "accepts string-keyed envelope aliases when atom forms are absent" do
      projections = %{
        "read_only" => base_projections().read_only,
        "read_write" => base_projections().read_write,
        "revision" => "candidate"
      }

      assert {:ok, spec} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: projections)}))

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
    @tag :security_regression
    test "security regression: admits Actions envelope and rejects flat/runtime-parent shape" do
      assert {:ok, spec} =
               Core.new(
                 valid_request(%{opts: valid_opts(filesystem_projections: base_projections())})
               )

      assert spec.plan.projections.worktree == @worktree
      assert spec.plan.projections.home == "/private/tmp/arbor-val/home"
      assert spec.plan.projections.tmp == "/private/tmp/arbor-val/tmp"
      assert spec.plan.projections.build == "/private/tmp/arbor-val/build"
      assert spec.plan.projections.deps == "/private/tmp/arbor-val/deps"
      assert spec.plan.projections.mix_wrapper == @mix_wrapper
      refute Map.has_key?(spec.plan.projections, :runtime)

      # Legacy flat purpose map (including retired runtime parent) is not an envelope.
      assert {:error, reason_flat} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts(filesystem_projections: legacy_flat_projections())
                 })
               )

      assert reason_flat in [
               :invalid_filesystem_projections,
               :unsupported_filesystem_projection_keys,
               :missing_filesystem_projection_key
             ] or match?({:unsupported_filesystem_projection_keys, _}, reason_flat) or
               match?({:missing_filesystem_projection_key, _}, reason_flat)

      # Legacy list form rejected.
      list = Enum.flat_map([:read_only, :read_write], &Map.fetch!(base_projections(), &1))

      assert {:error, :invalid_filesystem_projections} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: list)}))

      # Runtime parent purpose inside an otherwise envelope-shaped payload.
      with_runtime =
        Map.update!(base_projections(), :read_write, fn list ->
          list ++
            [
              %{
                "path" => "/private/tmp/arbor-val/runtime",
                "mode" => "read_write",
                "purpose" => "runtime"
              }
            ]
        end)

      assert {:error, reason_runtime} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: with_runtime)}))

      assert reason_runtime in [
               :extra_projections,
               :runtime_parent_projection_forbidden
             ]
    end

    test "rejects missing, extra, mode swap, duplicates, and overlap" do
      missing = delete_group_entry(base_projections(), :read_write, :deps)

      assert {:error, {:missing_projections, [:deps]}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: missing)}))

      extra =
        Map.update!(base_projections(), :read_write, fn list ->
          list ++ [actions_entry("/tmp/evil", :read_write, :worktree)]
        end)

      assert {:error, reason_extra} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: extra)}))

      assert reason_extra in [:extra_projections, :duplicate_projection_purpose]

      swapped =
        put_group_entry(
          base_projections(),
          :read_write,
          :worktree,
          actions_entry(@worktree, :read_only, :worktree)
        )

      assert {:error, reason_mode} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: swapped)}))

      assert reason_mode in [
               {:projection_group_mode_mismatch, :read_write, :read_only},
               {:projection_mode_mismatch, :worktree, :read_only}
             ]

      wrong_group =
        base_projections()
        |> delete_group_entry(:read_write, :worktree)
        |> Map.update!(:read_only, fn list ->
          list ++ [actions_entry(@worktree, :read_only, :worktree)]
        end)

      assert {:error, reason_group} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: wrong_group)}))

      assert reason_group in [
               {:projection_purpose_group_mismatch, :worktree, :read_only},
               {:missing_projections, [:worktree]},
               :extra_projections
             ] or match?({:projection_purpose_group_mismatch, :worktree, _}, reason_group) or
               match?({:missing_projections, _}, reason_group)

      dup_paths =
        put_group_entry(
          base_projections(),
          :read_write,
          :home,
          actions_entry(@worktree, :read_write, :home)
        )

      assert {:error, :duplicate_projection_paths} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: dup_paths)}))

      overlap =
        put_group_entry(
          base_projections(),
          :read_write,
          :tmp,
          actions_entry(@worktree <> "/nested", :read_write, :tmp)
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

    test "rejects duplicate envelope and entry key aliases" do
      bad_envelope =
        base_projections()
        |> Map.put("read_only", base_projections().read_only)

      assert {:error, {:duplicate_filesystem_projection_key_alias, :read_only}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: bad_envelope)}))

      bad_entry =
        put_group_entry(
          base_projections(),
          :read_write,
          :home,
          %{
            "path" => "/private/tmp/arbor-val/home",
            "mode" => "read_write",
            "purpose" => "home",
            path: "/private/tmp/arbor-val/home"
          }
        )

      assert {:error, {:duplicate_projection_entry_key_alias, :path}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: bad_entry)}))
    end

    test "rejects invalid revision and missing envelope groups" do
      bad_rev = Map.put(base_projections(), :revision, "staging")

      assert {:error, :invalid_projection_revision} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: bad_rev)}))

      missing_group = Map.delete(base_projections(), :revision)

      assert {:error, {:missing_filesystem_projection_key, [:revision]}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: missing_group)}))
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
