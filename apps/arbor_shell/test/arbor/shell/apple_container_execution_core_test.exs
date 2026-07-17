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
  @mix_wrapper_dir "/private/tmp/arbor-val/bin"
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
      assert shown["plan"]["resource_profile"] == "standard"
      assert shown["plan"]["resource_limits"] == %{"cpus" => "1", "memory" => "2G"}
      refute inspect(shown) =~ "super-secret"
      refute Map.has_key?(shown, "env")
    end

    test "defaults to standard resource profile 1 CPU / 2G" do
      assert {:ok, spec} = Core.new(valid_request(%{args: ["compile"]}))
      assert spec.plan.resource_profile == :standard
      assert spec.plan.resource_limits == %{cpus: "1", memory: "2G"}

      create = spec.plan.argv.create
      cpus_idx = Enum.find_index(create, &(&1 == "--cpus"))
      memory_idx = Enum.find_index(create, &(&1 == "--memory"))
      assert Enum.at(create, cpus_idx + 1) == "1"
      assert Enum.at(create, memory_idx + 1) == "2G"
    end

    test "intensive resource profile produces 4 CPU / 4G create argv" do
      assert {:ok, spec} =
               Core.new(valid_request(%{opts: valid_opts(resource_profile: :intensive)}))

      assert spec.plan.resource_profile == :intensive
      assert spec.plan.resource_limits == %{cpus: "4", memory: "4G"}

      create = spec.plan.argv.create
      cpus_idx = Enum.find_index(create, &(&1 == "--cpus"))
      memory_idx = Enum.find_index(create, &(&1 == "--memory"))
      assert Enum.at(create, cpus_idx + 1) == "4"
      assert Enum.at(create, memory_idx + 1) == "4G"

      shown = Core.show(spec)
      assert shown["plan"]["resource_profile"] == "intensive"
      assert shown["plan"]["resource_limits"] == %{"cpus" => "4", "memory" => "4G"}
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
        assert spec.plan.projections.mix_wrapper_dir == @mix_wrapper_dir
        refute Map.has_key?(spec.plan.projections, :mix_wrapper)
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
    @tag :security_regression
    test "security regression: invalid resource profiles and raw limit opts fail closed" do
      # Strings, maps, unknown atoms, integers, booleans, and nil all fail closed.
      for bad <- [
            :turbo,
            :high,
            :standard_plus,
            "standard",
            "intensive",
            "4",
            4,
            4.0,
            true,
            false,
            nil,
            %{cpus: "4", memory: "4G"},
            %{"cpus" => "4"},
            [:intensive],
            {:standard}
          ] do
        assert {:error, :invalid_resource_profile} =
                 Core.new(valid_request(%{opts: valid_opts(resource_profile: bad)})),
               "expected rejection for profile #{inspect(bad)}"
      end

      # Raw capacity opts are never admitted (no exceptions for any of these keys).
      for key <- [:cpus, :memory, :resource_limits, :resources] do
        assert {:error, {:unsupported_opt_keys, _}} =
                 Core.new(valid_request(%{opts: valid_opts() ++ [{key, "4"}]})),
               "expected rejection for open opt #{inspect(key)}"
      end

      assert {:error, {:unsupported_opt_keys, _}} =
               Core.new(valid_request(%{opts: valid_opts() ++ [cpus: "99"]}))

      assert {:error, {:unsupported_opt_keys, _}} =
               Core.new(valid_request(%{opts: valid_opts() ++ [memory: "99G"]}))

      assert {:error, {:unsupported_opt_keys, _}} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts() ++ [resource_limits: %{cpus: "4", memory: "4G"}]
                 })
               )

      # Preflight shares the same fail-closed reasons without admission.
      assert {:error, :invalid_resource_profile} =
               Core.validate_request(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(resource_profile: "intensive")
               )

      assert {:error, :invalid_resource_profile} =
               Core.validate_request(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(resource_profile: %{cpus: "4"})
               )

      assert {:error, {:unsupported_opt_keys, _}} =
               Core.validate_request(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts() ++ [cpus: "4", memory: "4G"]
               )
    end

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
      ceiling = Shell.spawn_capable_max_timeout_ms()

      assert {:ok, spec} =
               Core.new(valid_request(%{opts: valid_opts(timeout: ceiling)}))

      assert spec.timeout_ms == ceiling

      assert {:error, :timeout_too_large} =
               Core.new(valid_request(%{opts: valid_opts(timeout: ceiling + 1)}))

      assert {:error, :timeout_too_small} =
               Core.new(valid_request(%{opts: valid_opts(timeout: 0)}))

      assert {:error, :max_output_bytes_too_large} =
               Core.new(valid_request(%{opts: valid_opts(max_output_bytes: 16_777_217)}))

      assert {:error, :invalid_max_output_bytes} =
               Core.new(valid_request(%{opts: valid_opts(max_output_bytes: 0)}))
    end

    @tag :security_regression
    test "security regression: profile-aware timeout ceilings reject mismatches" do
      standard_ceiling = Shell.spawn_capable_max_timeout_ms()
      assert standard_ceiling == 600_000
      assert {:ok, intensive_ceiling} = Shell.spawn_capable_max_timeout_ms(:intensive)
      assert intensive_ceiling == 1_200_000

      # Standard rejects above 600_000 without clamping.
      assert {:error, :timeout_too_large} =
               Core.new(valid_request(%{opts: valid_opts(timeout: standard_ceiling + 1)}))

      assert {:error, :timeout_too_large} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts(timeout: intensive_ceiling, resource_profile: :standard)
                 })
               )

      # Intensive admits up to 1_200_000 and rejects larger / unknown profiles.
      assert {:ok, intensive_spec} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts(timeout: intensive_ceiling, resource_profile: :intensive)
                 })
               )

      assert intensive_spec.timeout_ms == intensive_ceiling
      assert intensive_spec.plan.resource_profile == :intensive

      assert {:error, :timeout_too_large} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts(timeout: intensive_ceiling + 1, resource_profile: :intensive)
                 })
               )

      assert {:error, :invalid_resource_profile} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts(timeout: intensive_ceiling, resource_profile: :turbo)
                 })
               )
    end

    test "spawn-capable timeout ceiling is the shared Shell source of truth" do
      assert Shell.spawn_capable_max_timeout_ms() == 600_000
      assert {:ok, 1_200_000} = Shell.spawn_capable_max_timeout_ms(:intensive)
      assert {:error, :invalid_resource_profile} = Shell.spawn_capable_max_timeout_ms(:turbo)

      assert Arbor.Shell.SpawnCapableTimeout.max_timeout_ms() ==
               Shell.spawn_capable_max_timeout_ms()

      assert Arbor.Shell.SpawnCapableTimeout.max_timeout_ms(:intensive) ==
               Shell.spawn_capable_max_timeout_ms(:intensive)
    end
  end

  describe "projection validation" do
    @tag :security_regression
    test "security regression: file wrapper authority becomes an exact read-only directory bind" do
      projections = base_projections()
      wrapper_entry = Enum.find(projections.read_only, &(&1["purpose"] == "mix_wrapper"))

      request =
        valid_request(%{opts: valid_opts(filesystem_projections: projections)})

      # Actions and tool authority remain the exact reviewed wrapper file.
      assert wrapper_entry["path"] == @mix_wrapper
      assert request.tool_name == wrapper_entry["path"]

      assert {:ok, spec} = Core.new(request)
      assert spec.plan.projections.mix_wrapper_dir == @mix_wrapper_dir
      refute Map.has_key?(spec.plan.projections, :mix_wrapper)

      wrapper_mount = Enum.find(spec.plan.mounts, &(&1.purpose == :mix_wrapper_dir))

      assert wrapper_mount == %{
               purpose: :mix_wrapper_dir,
               host_path: @mix_wrapper_dir,
               guest_path: "/arbor/bin",
               mode: :read_only,
               mount_spec:
                 "type=bind,source=/private/tmp/arbor-val/bin,target=/arbor/bin,readonly"
             }

      # Incoming envelope still requires :tmp; Apple plan omits host tmp entirely.
      assert Enum.any?(
               base_projections().read_write,
               &(&1["purpose"] == "tmp" and &1["path"] == "/private/tmp/arbor-val/tmp")
             )

      refute Map.has_key?(spec.plan.projections, :tmp)
      refute Enum.any?(spec.plan.mounts, &(&1.purpose == :tmp))
      refute Enum.any?(spec.plan.mounts, &(&1.guest_path == "/tmp"))
      refute String.contains?(inspect(spec.plan), "/private/tmp/arbor-val/tmp")

      assert spec.plan.guest_tmpfs == %{
               guest_path: "/tmp",
               argv_spec: "/tmp"
             }

      create = spec.plan.argv.create
      assert Enum.count(create, &(&1 == "--tmpfs")) == 1
      tmpfs_idx = Enum.find_index(create, &(&1 == "--tmpfs"))
      assert Enum.at(create, tmpfs_idx + 1) == "/tmp"
      refute String.contains?(Enum.at(create, tmpfs_idx + 1), "size=")
      refute String.contains?(Enum.at(create, tmpfs_idx + 1), "mode=")
      refute Enum.any?(create, &String.contains?(&1, "type=tmpfs"))
      refute Enum.any?(create, &String.contains?(&1, "source=/private/tmp/arbor-val/tmp"))
      refute Enum.any?(create, &String.contains?(&1, "target=/tmp"))

      assert wrapper_mount.mount_spec in create
      refute @mix_wrapper in create

      # The derived directory is mount data only, never alternate tool authority.
      assert {:error, :tool_name_mix_wrapper_mismatch} =
               Core.new(%{request | tool_name: @mix_wrapper_dir})
    end

    @tag :security_regression
    test "security regression: admits Actions envelope and rejects flat/runtime-parent shape" do
      assert {:ok, spec} =
               Core.new(
                 valid_request(%{opts: valid_opts(filesystem_projections: base_projections())})
               )

      assert spec.plan.projections.worktree == @worktree
      assert spec.plan.projections.home == "/private/tmp/arbor-val/home"
      assert spec.plan.projections.build == "/private/tmp/arbor-val/build"
      assert spec.plan.projections.deps == "/private/tmp/arbor-val/deps"
      assert spec.plan.projections.mix_wrapper_dir == @mix_wrapper_dir
      refute Map.has_key?(spec.plan.projections, :tmp)
      refute Map.has_key?(spec.plan.projections, :mix_wrapper)
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

      # Owner resource envelope still requires :tmp for lifecycle accounting.
      missing_tmp = delete_group_entry(base_projections(), :read_write, :tmp)

      assert {:error, {:missing_projections, [:tmp]}} =
               Core.new(valid_request(%{opts: valid_opts(filesystem_projections: missing_tmp)}))

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

    test "rejects malformed or root wrapper parents with a bounded reason" do
      for wrapper_path <- ["/mix", "/private/tmp/arbor-val/bin/not-mix"] do
        projections =
          put_group_entry(
            base_projections(),
            :read_only,
            :mix_wrapper,
            actions_entry(wrapper_path, :read_only, :mix_wrapper)
          )

        opts = valid_opts(filesystem_projections: projections)

        assert {:error, :invalid_mix_wrapper_mount_source} =
                 Core.validate_request(wrapper_path, ["compile"], opts)

        assert {:error, :invalid_mix_wrapper_mount_source} =
                 Core.new(valid_request(%{tool_name: wrapper_path, opts: opts}))
      end
    end

    @tag :security_regression
    test "rejects overlap introduced only by the derived wrapper directory" do
      wrapper_path = "/private/tmp/arbor-val/shared-bin/mix"
      nested_worktree = "/private/tmp/arbor-val/shared-bin/worktree"

      projections =
        base_projections()
        |> put_group_entry(
          :read_only,
          :mix_wrapper,
          actions_entry(wrapper_path, :read_only, :mix_wrapper)
        )
        |> put_group_entry(
          :read_write,
          :worktree,
          actions_entry(nested_worktree, :read_write, :worktree)
        )

      opts = valid_opts(cwd: nested_worktree, filesystem_projections: projections)

      assert {:error, {:overlapping_projection_paths, :mix_wrapper_dir, :worktree}} =
               Core.validate_request(wrapper_path, ["compile"], opts)
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

  describe "validate_request/3 preflight" do
    test "accepts a valid facade request without admission or unit_name" do
      assert :ok = Core.validate_request(@mix_wrapper, ["compile"], valid_opts())
      assert :ok = Core.validate_request(@mix_wrapper, ["test", "--only", "fast"], valid_opts())
      assert :ok = Core.validate_request(@mix_wrapper, ["quality"], valid_opts())
    end

    test "returns :ok only — never a prepared authority object" do
      assert :ok == Core.validate_request(@mix_wrapper, ["compile"], valid_opts())
      refute match?({:ok, _}, Core.validate_request(@mix_wrapper, ["compile"], valid_opts()))
    end

    test "rejects malformed tool_name, args, and opts before admission is needed" do
      assert {:error, :invalid_tool_name} =
               Core.validate_request(:not_a_path, ["compile"], valid_opts())

      assert {:error, {:invalid_tool_name, _}} =
               Core.validate_request("relative/mix", ["compile"], valid_opts())

      assert {:error, :invalid_args} =
               Core.validate_request(@mix_wrapper, "compile", valid_opts())

      assert {:error, :empty_command_args} =
               Core.validate_request(@mix_wrapper, [], valid_opts())

      assert {:error, :unsupported_mix_command} =
               Core.validate_request(@mix_wrapper, ["deps.get"], valid_opts())

      assert {:error, :invalid_opts} =
               Core.validate_request(@mix_wrapper, ["compile"], %{cwd: @worktree})

      assert {:error, :stdin_not_supported} =
               Core.validate_request(@mix_wrapper, ["compile"], valid_opts() ++ [stdin: "x"])

      assert {:error, {:missing_opt_keys, _}} =
               Core.validate_request(
                 @mix_wrapper,
                 ["compile"],
                 timeout: 1,
                 sandbox: :basic,
                 env: %{},
                 clear_env: true,
                 filesystem_projections: base_projections()
               )
    end

    test "rejects projection, tool/cwd, and MIX_ENV failures without admission" do
      assert {:error, flat_reason} =
               Core.validate_request(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(filesystem_projections: legacy_flat_projections())
               )

      assert flat_reason in [
               :invalid_filesystem_projections,
               :unsupported_filesystem_projection_keys,
               :missing_filesystem_projection_key
             ] or match?({:unsupported_filesystem_projection_keys, _}, flat_reason) or
               match?({:missing_filesystem_projection_key, _}, flat_reason)

      assert {:error, :tool_name_mix_wrapper_mismatch} =
               Core.validate_request("/usr/bin/mix", ["compile"], valid_opts())

      assert {:error, :cwd_worktree_mismatch} =
               Core.validate_request(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(cwd: "/private/tmp/other")
               )

      assert {:error, :disallowed_mix_env} =
               Core.validate_request(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(env: %{"MIX_ENV" => "staging"})
               )
    end

    test "preflight and new/1 share the same error reasons for request faults" do
      bad_args = ["run", "-e", "1"]

      assert {:error, preflight_reason} =
               Core.validate_request(@mix_wrapper, bad_args, valid_opts())

      assert {:error, ^preflight_reason} = Core.new(valid_request(%{args: bad_args}))

      bad_opts = valid_opts(sandbox: :none)

      assert {:error, :invalid_sandbox} =
               Core.validate_request(@mix_wrapper, ["compile"], bad_opts)

      assert {:error, :invalid_sandbox} =
               Core.new(valid_request(%{opts: bad_opts}))
    end
  end

  describe "public spawn facade preflight" do
    test "relative tool is pure preflight before admission" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end
  end
end
