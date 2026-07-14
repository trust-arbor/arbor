defmodule Arbor.Shell.AppleContainerPlanCoreTest do
  @moduledoc """
  Focused pure adversarial tests for Apple Container request/command-plan core.

  Slice 2A only: validates immutable argv plans as data. Does not wire
  `Arbor.Shell.execute_spawn_capable/3` (still production_backend_missing).
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerPlanCore

  @moduletag :fast
  @moduletag :security_regression

  @digest String.duplicate("a", 64)
  @image "arbor/validation@sha256:#{@digest}"
  @name "arbor-val-unit01"

  @projections %{
    worktree: "/private/tmp/arbor-val/worktree",
    home: "/private/tmp/arbor-val/home",
    tmp: "/private/tmp/arbor-val/tmp",
    build: "/private/tmp/arbor-val/build",
    deps: "/private/tmp/arbor-val/deps",
    runtime: "/private/tmp/arbor-val/runtime",
    mix_wrapper: "/private/tmp/arbor-val/bin/mix"
  }

  @host_runtime_roots %{
    erlang: "/opt/homebrew/Cellar/erlang/28.4.1/lib/erlang",
    elixir: "/opt/homebrew/Cellar/elixir/1.19.5/bin/.."
  }

  # Host elixir root must itself be absolute canonical without dot segments.
  @host_runtime_roots_valid %{
    erlang: "/opt/homebrew/Cellar/erlang/28.4.1/lib/erlang",
    elixir: "/opt/homebrew/Cellar/elixir/1.19.5"
  }

  @valid_request %{
    image: @image,
    name: @name,
    projections: @projections,
    host_runtime_roots: @host_runtime_roots_valid,
    mix_env: "test",
    command_args: ["test", "apps/arbor_shell/test/example_test.exs"]
  }

  # Invalid UTF-8 binary (lone continuation byte) — must never raise.
  @invalid_utf8 <<0xC3, 0x28>>

  describe "positive exact create plan" do
    test "builds full containment argv with fixed mounts, env, limits, and cleanup" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)

      assert plan.runtime_executable == "/usr/local/bin/container"
      assert plan.unit_name == @name
      assert plan.image == @image
      assert plan.mix_env == "test"
      assert plan.command_args == ["test", "apps/arbor_shell/test/example_test.exs"]
      assert plan.guest_workdir == "/workspace"
      assert plan.guest_mix_wrapper == "/arbor/bin/mix"

      assert plan.guest_runtime_roots == %{
               erlang: "/usr/local/lib/erlang",
               elixir: "/usr/local"
             }

      assert plan.resource_limits == %{cpus: "1", memory: "2G"}
      assert plan.lifecycle.start_order == [:create, :start]
      assert plan.lifecycle.terminal_order == [:force_stop, :delete, :verify_absent]

      create = plan.argv.create

      assert create ==
               [
                 "/usr/local/bin/container",
                 "create",
                 "--name",
                 @name,
                 "--network",
                 "none",
                 "--init",
                 "--read-only",
                 "--cap-drop",
                 "ALL",
                 "--cpus",
                 "1",
                 "--memory",
                 "2G",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/worktree,target=/workspace",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/home,target=/arbor/home",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/tmp,target=/arbor/tmp",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/build,target=/arbor/build",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/deps,target=/arbor/deps",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/runtime,target=/arbor/runtime",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/bin/mix,target=/arbor/bin/mix,readonly",
                 "--workdir",
                 "/workspace",
                 "--env",
                 "HOME=/arbor/home",
                 "--env",
                 "TMPDIR=/arbor/tmp",
                 "--env",
                 "MIX_BUILD_PATH=/arbor/build",
                 "--env",
                 "MIX_DEPS_PATH=/arbor/deps",
                 "--env",
                 "ARBOR_MIX_CONTAINED=1",
                 "--env",
                 "ARBOR_ERLANG_ROOT=/usr/local/lib/erlang",
                 "--env",
                 "ARBOR_ELIXIR_ROOT=/usr/local",
                 "--env",
                 "MIX_ENV=test",
                 "--entrypoint",
                 "/arbor/bin/mix",
                 @image,
                 "test",
                 "apps/arbor_shell/test/example_test.exs"
               ]

      assert plan.argv.start == [
               "/usr/local/bin/container",
               "start",
               "--attach",
               @name
             ]

      assert plan.argv.force_stop == [
               "/usr/local/bin/container",
               "kill",
               "--signal",
               "KILL",
               @name
             ]

      assert plan.argv.delete == [
               "/usr/local/bin/container",
               "delete",
               @name
             ]

      assert plan.argv.verify_absent == [
               "/usr/local/bin/container",
               "inspect",
               @name
             ]

      # Host runtime roots are provenance only — never mounted.
      create_joined = Enum.join(create, " ")
      refute String.contains?(create_joined, @host_runtime_roots_valid.erlang)
      refute String.contains?(create_joined, @host_runtime_roots_valid.elixir)

      # Guest runtime roots appear only as closed env values, not as mount sources.
      mount_specs =
        plan.mounts
        |> Enum.map(& &1.mount_spec)
        |> Enum.join(" ")

      refute String.contains?(mount_specs, "/usr/local/lib/erlang")
      refute String.contains?(mount_specs, "target=/usr/local,")
      refute String.contains?(mount_specs, "target=/usr/local/")

      assert Enum.map(plan.mounts, & &1.guest_path) == [
               "/workspace",
               "/arbor/home",
               "/arbor/tmp",
               "/arbor/build",
               "/arbor/deps",
               "/arbor/runtime",
               "/arbor/bin/mix"
             ]

      assert Enum.map(plan.mounts, & &1.mode) == [
               :read_write,
               :read_write,
               :read_write,
               :read_write,
               :read_write,
               :read_write,
               :read_only
             ]

      refute_forbidden_tokens(plan)
    end

    test "is deterministic for the same request" do
      assert {:ok, a} = AppleContainerPlanCore.new(@valid_request)
      assert {:ok, b} = AppleContainerPlanCore.new(@valid_request)
      assert a == b
      assert AppleContainerPlanCore.show(a) == AppleContainerPlanCore.show(b)
    end

    test "accepts string-keyed request maps" do
      request = %{
        "image" => @image,
        "name" => @name,
        "projections" => %{
          "worktree" => @projections.worktree,
          "home" => @projections.home,
          "tmp" => @projections.tmp,
          "build" => @projections.build,
          "deps" => @projections.deps,
          "runtime" => @projections.runtime,
          "mix_wrapper" => @projections.mix_wrapper
        },
        "host_runtime_roots" => %{
          "erlang" => @host_runtime_roots_valid.erlang,
          "elixir" => @host_runtime_roots_valid.elixir
        },
        "mix_env" => "prod",
        "command_args" => ["compile"]
      }

      assert {:ok, plan} = AppleContainerPlanCore.new(request)
      assert plan.mix_env == "prod"
      assert Enum.take(plan.argv.create, -1) == ["compile"]
      assert "MIX_ENV=prod" in plan.argv.create
    end

    test "allows each closed MIX_ENV value" do
      for mix_env <- AppleContainerPlanCore.allowed_mix_envs() do
        assert {:ok, plan} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :mix_env, mix_env))

        assert plan.mix_env == mix_env
        assert "MIX_ENV=#{mix_env}" in plan.argv.create
      end
    end
  end

  describe "duplicate atom/string request key aliases" do
    @tag :security_regression
    test "rejects atom+string aliases even when values are identical" do
      cases = [
        :image,
        :name,
        :projections,
        :host_runtime_roots,
        :mix_env,
        :command_args
      ]

      for atom_key <- cases do
        string_key = Atom.to_string(atom_key)
        value = Map.fetch!(@valid_request, atom_key)

        request =
          @valid_request
          |> Map.put(atom_key, value)
          |> Map.put(string_key, value)

        assert {:error, {:duplicate_request_key_alias, ^atom_key}} =
                 AppleContainerPlanCore.new(request),
               "expected duplicate alias rejection for #{inspect(atom_key)}"
      end
    end

    @tag :security_regression
    test "rejects atom+string aliases when values differ" do
      request =
        @valid_request
        |> Map.put(:image, @image)
        |> Map.put("image", "other/image@sha256:#{@digest}")

      assert {:error, {:duplicate_request_key_alias, :image}} =
               AppleContainerPlanCore.new(request)
    end
  end

  describe "invalid UTF-8 fail-closed" do
    @tag :security_regression
    test "table: every accepted textual input path rejects invalid UTF-8 without raising" do
      cases = [
        {:image, Map.put(@valid_request, :image, @invalid_utf8)},
        {:name, Map.put(@valid_request, :name, @invalid_utf8)},
        {:mix_env, Map.put(@valid_request, :mix_env, @invalid_utf8)},
        {:command_args, Map.put(@valid_request, :command_args, ["test", @invalid_utf8])},
        {:projection_worktree,
         Map.put(
           @valid_request,
           :projections,
           Map.put(@projections, :worktree, "/private/tmp/" <> @invalid_utf8)
         )},
        {:projection_mix_wrapper,
         Map.put(
           @valid_request,
           :projections,
           Map.put(@projections, :mix_wrapper, "/private/tmp/mix" <> @invalid_utf8)
         )},
        {:host_runtime_erlang,
         Map.put(
           @valid_request,
           :host_runtime_roots,
           %{
             erlang: "/opt/erlang" <> @invalid_utf8,
             elixir: @host_runtime_roots_valid.elixir
           }
         )},
        {:host_runtime_elixir,
         Map.put(
           @valid_request,
           :host_runtime_roots,
           %{
             erlang: @host_runtime_roots_valid.erlang,
             elixir: "/opt/elixir" <> @invalid_utf8
           }
         )}
      ]

      for {label, request} <- cases do
        result =
          try do
            AppleContainerPlanCore.new(request)
          rescue
            exception ->
              flunk(
                "invalid UTF-8 path #{inspect(label)} raised #{inspect(exception.__struct__)}: #{Exception.message(exception)}"
              )
          end

        assert {:error, reason} = result,
               "label=#{inspect(label)} expected error, got #{inspect(result)}"

        assert reason == :invalid_utf8 or
                 (is_tuple(reason) and
                    elem(reason, 0) in [:invalid_projection, :invalid_host_runtime_root] and
                    elem(reason, tuple_size(reason) - 1) == :invalid_utf8),
               "label=#{inspect(label)} got #{inspect(reason)}, expected :invalid_utf8 envelope"
      end
    end
  end

  describe "image rejection" do
    @tag :security_regression
    test "table: tag-only, mutable, uppercase, malformed, option-shaped images" do
      cases = [
        {"alpine:latest", :mutable_image_tag},
        {"arbor/validation:v1", :mutable_image_tag},
        {"arbor/validation", :mutable_image_tag},
        {"arbor/validation@sha256:#{String.upcase(@digest)}", :uppercase_image_digest},
        {"arbor/validation@SHA256:#{@digest}", :uppercase_image_digest},
        {"arbor/validation@sha256:abcd", :malformed_image_digest},
        {"arbor/validation@sha256:#{String.duplicate("g", 64)}", :malformed_image_digest},
        {"arbor/validation@sha256:#{String.duplicate("a", 63)}", :malformed_image_digest},
        {"arbor/validation@sha256:#{String.duplicate("a", 65)}", :malformed_image_digest},
        {"arbor/validation @sha256:#{@digest}", :unsafe_image},
        {"arbor/validation@sha256:#{@digest}\n", :unsafe_image},
        {"--pull", :option_shaped_image},
        {"-e", :option_shaped_image},
        {"", :empty_image}
      ]

      for {image, expected} <- cases do
        assert {:error, reason} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :image, image))

        assert reason == expected or
                 (is_tuple(reason) and elem(reason, 0) == expected) or
                 reason in [
                   :malformed_image,
                   :malformed_image_digest,
                   :mutable_image_tag,
                   :uppercase_image_digest,
                   :unsafe_image,
                   :option_shaped_image,
                   :empty_image,
                   :invalid_image
                 ],
               "image=#{inspect(image)} got #{inspect(reason)}, expected ~#{inspect(expected)}"
      end
    end
  end

  describe "name rejection" do
    test "table: unsafe, option-shaped, shell-like, oversized names" do
      cases = [
        {"", :empty_name},
        {"a", :name_too_short},
        {String.duplicate("a", 64), :name_too_long},
        {"--all", :option_shaped_name},
        {"-f", :option_shaped_name},
        {"UPPER", :unsafe_name},
        {"has space", :unsafe_name},
        {"has_under", :unsafe_name},
        {"has.dot", :unsafe_name},
        {"semi;colon", :unsafe_name},
        {"star*", :unsafe_name},
        {"dollar$value", :unsafe_name},
        {"back`tick", :unsafe_name},
        {"-leading", :option_shaped_name},
        {"trailing-", :unsafe_name},
        {"../escape", :unsafe_name}
      ]

      for {name, expected} <- cases do
        assert {:error, reason} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :name, name))

        assert reason == expected,
               "name=#{inspect(name)} got #{inspect(reason)}, expected #{inspect(expected)}"
      end
    end
  end

  describe "projection rejection" do
    test "rejects relative, dot-segment, duplicate, missing, and unsafe paths" do
      cases = [
        {{:worktree, "relative/worktree"}, :relative_path},
        {{:home, "/tmp/./home"}, :dot_segment},
        {{:tmp, "/tmp/foo/../tmp"}, :dot_segment},
        {{:build, "/tmp//double"}, :non_canonical_path},
        {{:deps, "/tmp/deps/"}, :trailing_slash},
        {{:runtime, "/tmp/run\0time"}, :nul_byte},
        {{:mix_wrapper, "/tmp/mix\nwrapper"}, :control_char},
        {{:worktree, "/tmp/work tree"}, :whitespace_in_path}
      ]

      for {{key, bad_path}, expected_reason} <- cases do
        projections = Map.put(@projections, key, bad_path)

        assert {:error, {:invalid_projection, ^key, ^expected_reason}} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :projections, projections))
      end

      # Duplicate host paths across purposes.
      dup = Map.put(@projections, :home, @projections.worktree)

      assert {:error, :duplicate_projection_paths} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, dup))

      # Missing required projection.
      missing = Map.delete(@projections, :deps)

      assert {:error, {:missing_projections, [:deps]}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, missing))

      # Missing projections field entirely.
      assert {:error, :missing_projections} =
               AppleContainerPlanCore.new(Map.delete(@valid_request, :projections))
    end

    @tag :security_regression
    test "rejects mount mini-language field delimiters in projection host paths" do
      # Comma-delimited --mount field injection: source cannot inject target= or readonly.
      injected =
        "/private/tmp/arbor-val/evil,target=/evil,readonly"

      projections = Map.put(@projections, :worktree, injected)

      assert {:error, {:invalid_projection, :worktree, :mount_field_delimiter}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, projections))

      # Equals alone can re-key mount fields if a future renderer re-parses loosely.
      eq_injected = "/private/tmp/arbor-val/path=target"

      assert {:error, {:invalid_projection, :home, :mount_field_delimiter}} =
               AppleContainerPlanCore.new(
                 Map.put(
                   @valid_request,
                   :projections,
                   Map.put(@projections, :home, eq_injected)
                 )
               )

      # Prove a successful plan never embeds an injected target= from source material.
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      worktree_spec = Enum.find(plan.mounts, &(&1.purpose == :worktree)).mount_spec
      assert worktree_spec == "type=bind,source=/private/tmp/arbor-val/worktree,target=/workspace"
      refute String.contains?(worktree_spec, "target=/evil")
    end

    @tag :security_regression
    test "rejects segment-aware ancestor/descendant projection overlaps in both orders" do
      # Read/write worktree must never contain the read-only mix_wrapper source.
      nested_wrapper =
        Map.put(
          @projections,
          :mix_wrapper,
          @projections.worktree <> "/bin/mix"
        )

      assert {:error, {:overlapping_projection_paths, a, b}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_wrapper))

      assert MapSet.new([a, b]) == MapSet.new([:worktree, :mix_wrapper])

      # Reverse order of nesting: worktree under home (both read/write — must not nest).
      nested_worktree =
        @projections
        |> Map.put(:home, "/private/tmp/arbor-val/base")
        |> Map.put(:worktree, "/private/tmp/arbor-val/base/worktree")

      assert {:error, {:overlapping_projection_paths, c, d}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_worktree))

      assert MapSet.new([c, d]) == MapSet.new([:home, :worktree])

      # Read/write roots must not nest either direction (tmp under build).
      nested_tmp =
        @projections
        |> Map.put(:build, "/private/tmp/arbor-val/build-root")
        |> Map.put(:tmp, "/private/tmp/arbor-val/build-root/tmp")

      assert {:error, {:overlapping_projection_paths, e, f}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_tmp))

      assert MapSet.new([e, f]) == MapSet.new([:build, :tmp])

      # Opposite nesting direction (build under tmp).
      nested_build =
        @projections
        |> Map.put(:tmp, "/private/tmp/arbor-val/tmp-root")
        |> Map.put(:build, "/private/tmp/arbor-val/tmp-root/build")

      assert {:error, {:overlapping_projection_paths, g, h}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_build))

      assert MapSet.new([g, h]) == MapSet.new([:tmp, :build])
    end

    @tag :security_regression
    test "allows sibling path-prefix non-overlap (not raw String.starts_with?)" do
      # /.../work and /.../worktree share a string prefix but not a path segment ancestor.
      sibling =
        @projections
        |> Map.put(:worktree, "/private/tmp/arbor-val/work")
        |> Map.put(:home, "/private/tmp/arbor-val/worktree")

      assert {:ok, plan} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, sibling))

      assert plan.projections.worktree == "/private/tmp/arbor-val/work"
      assert plan.projections.home == "/private/tmp/arbor-val/worktree"
    end

    test "rejects caller-controlled guest targets / mount mode weakening keys" do
      # Guest targets and modes are not part of the request surface.
      assert {:error, {:unsupported_request_keys, keys}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :guest_targets, %{worktree: "/evil"})
               )

      assert Enum.any?(keys, &String.contains?(&1, "guest_targets"))

      assert {:error, {:unsupported_request_keys, _}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :mounts, [
                   %{source: "/x", target: "/y", mode: :read_write}
                 ])
               )

      assert {:error, {:unsupported_request_keys, _}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :extra_flags, ["--privileged"]))
    end
  end

  describe "environment and flag rejection" do
    test "rejects arbitrary env maps and disallowed MIX_ENV" do
      assert {:error, {:unsupported_request_keys, _}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :env, %{"PATH" => "/evil", "SECRET" => "x"})
               )

      assert {:error, {:unsupported_request_keys, _}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :environment, %{"HOME" => "/evil"})
               )

      for bad <- ["staging", "TEST", "dev;rm", "", "--env", "production"] do
        assert {:error, reason} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :mix_env, bad))

        assert reason in [:disallowed_mix_env, :unsafe_mix_env, :invalid_mix_env, :empty_image] or
                 reason == :disallowed_mix_env or reason == :unsafe_mix_env
      end
    end

    test "rejects forbidden network modes and publish/ssh/privileged request fields" do
      for key <- [
            :network,
            :publish,
            :ssh,
            :privileged,
            :rm,
            :env_file,
            :cap_add,
            :read_only,
            :cpus,
            :memory
          ] do
        assert {:error, {:unsupported_request_keys, _}} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, key, "none"))
      end
    end
  end

  describe "cleanup breadth and forbidden tokens" do
    test "cleanup argv targets only the exact unit name" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)

      for key <- [:force_stop, :delete, :verify_absent] do
        argv = Map.fetch!(plan.argv, key)
        assert @name in argv
        refute "--all" in argv
        refute "-a" in argv
        refute Enum.any?(argv, &String.contains?(&1, "*"))
        # Exact ID only — no filter expressions.
        refute Enum.any?(argv, &String.contains?(&1, "name="))
      end

      # Delete is not --rm create; create never carries --rm.
      refute "--rm" in plan.argv.create
      refute "--remove" in plan.argv.create
    end

    test "positive plan never includes publish, ssh, env-file, privileged, or --rm/--all" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      refute_forbidden_tokens(plan)
    end

    test "facade remains fail-closed and unwired to this planner" do
      # Slice 2A does not wire the planner into execute_spawn_capable/3.
      assert {:error, {:spawn_backend_unavailable, :production_backend_missing}} =
               Arbor.Shell.execute_spawn_capable("mix", ["test"], cwd: "/tmp")
    end
  end

  describe "host runtime roots" do
    test "requires valid absolute host roots as provenance without mounting them" do
      assert {:error, :missing_host_runtime_roots} =
               AppleContainerPlanCore.new(Map.delete(@valid_request, :host_runtime_roots))

      assert {:error, {:invalid_host_runtime_root, :relative_path}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :host_runtime_roots, %{
                   erlang: "relative/erlang",
                   elixir: @host_runtime_roots_valid.elixir
                 })
               )

      assert {:error, {:invalid_host_runtime_root, :dot_segment}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :host_runtime_roots, %{
                   erlang: @host_runtime_roots_valid.erlang,
                   elixir: "/opt/elixir/../elixir"
                 })
               )

      # Invalid host_runtime_roots with `..` in @host_runtime_roots constant rejected.
      assert {:error, {:invalid_host_runtime_root, :dot_segment}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :host_runtime_roots, @host_runtime_roots)
               )
    end
  end

  describe "command args and entrypoint" do
    test "rejects control characters and non-list args" do
      assert {:error, :unsafe_command_arg} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :command_args, ["test", "a\0b"])
               )

      assert {:error, :invalid_command_args} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :command_args, "test"))

      assert {:error, :invalid_command_args} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :command_args, [:test]))
    end

    test "forces reviewed wrapper via --entrypoint; image followed only by command_args" do
      assert {:ok, plan} = AppleContainerPlanCore.new(Map.put(@valid_request, :command_args, []))
      create = plan.argv.create

      ep_idx = Enum.find_index(create, &(&1 == "--entrypoint"))
      assert is_integer(ep_idx)
      assert Enum.at(create, ep_idx + 1) == "/arbor/bin/mix"

      image_index = Enum.find_index(create, &(&1 == @image))
      assert is_integer(image_index)
      assert image_index == ep_idx + 2

      # After the image token: only caller command_args (empty here).
      assert Enum.drop(create, image_index + 1) == []

      # Exactly one /arbor/bin/mix token (entrypoint value), never a second post-image token.
      assert Enum.count(create, &(&1 == "/arbor/bin/mix")) == 1
    end

    test "appends only caller command_args after image" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      create = plan.argv.create
      image_index = Enum.find_index(create, &(&1 == @image))

      assert Enum.drop(create, image_index) == [
               @image,
               "test",
               "apps/arbor_shell/test/example_test.exs"
             ]

      refute Enum.at(create, image_index + 1) == "/arbor/bin/mix"
    end
  end

  describe "constants surface" do
    test "exports fixed executable, guest mounts, and resource limits" do
      assert AppleContainerPlanCore.runtime_executable() == "/usr/local/bin/container"

      assert AppleContainerPlanCore.guest_mount_table() == [
               {:worktree, "/workspace", :read_write},
               {:home, "/arbor/home", :read_write},
               {:tmp, "/arbor/tmp", :read_write},
               {:build, "/arbor/build", :read_write},
               {:deps, "/arbor/deps", :read_write},
               {:runtime, "/arbor/runtime", :read_write},
               {:mix_wrapper, "/arbor/bin/mix", :read_only}
             ]

      assert AppleContainerPlanCore.guest_runtime_roots() == %{
               erlang: "/usr/local/lib/erlang",
               elixir: "/usr/local"
             }

      assert AppleContainerPlanCore.resource_limits() == %{cpus: "1", memory: "2G"}
      assert AppleContainerPlanCore.allowed_mix_envs() == ["dev", "prod", "test"]
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp refute_forbidden_tokens(plan) do
    all_argv =
      plan.argv
      |> Map.values()
      |> List.flatten()

    joined = Enum.join(all_argv, " ")

    forbidden = [
      "--rm",
      "--remove",
      "--all",
      "--publish",
      "-p",
      "--ssh",
      "--env-file",
      "--privileged",
      "--cap-add",
      "--network=bridge",
      "--network=host",
      "network host",
      "network bridge"
    ]

    for token <- forbidden do
      refute String.contains?(joined, token),
             "forbidden token #{inspect(token)} present in argv: #{joined}"
    end

    # Network must be exactly none on create.
    create = plan.argv.create
    net_idx = Enum.find_index(create, &(&1 == "--network"))
    assert is_integer(net_idx)
    assert Enum.at(create, net_idx + 1) == "none"

    # No arbitrary env values beyond the closed set.
    env_values =
      create
      |> Enum.with_index()
      |> Enum.filter(fn {token, _} -> token == "--env" end)
      |> Enum.map(fn {_, idx} -> Enum.at(create, idx + 1) end)

    allowed_env_prefixes = [
      "HOME=",
      "TMPDIR=",
      "MIX_BUILD_PATH=",
      "MIX_DEPS_PATH=",
      "ARBOR_MIX_CONTAINED=",
      "ARBOR_ERLANG_ROOT=",
      "ARBOR_ELIXIR_ROOT=",
      "MIX_ENV="
    ]

    for env <- env_values do
      assert Enum.any?(allowed_env_prefixes, &String.starts_with?(env, &1)),
             "unexpected env entry #{inspect(env)}"
    end

    refute Enum.any?(env_values, &String.starts_with?(&1, "PATH="))
    refute Enum.any?(env_values, &String.starts_with?(&1, "SSH_"))
    refute Enum.any?(env_values, &String.contains?(&1, "SECRET"))
  end
end
