defmodule Arbor.Shell.AppleContainerPlanCoreTest do
  @moduledoc """
  Focused pure adversarial tests for Apple Container request/command-plan core.

  Slice 2A only: validates immutable argv plans as data. Does not wire
  `Arbor.Shell.execute_spawn_capable/3` public spawn facade.

  `:image` / `:init_image` are local execution aliases under the non-connectable
  sink `127.0.0.1:0/...@sha256:...` — never externally routable provisioning refs.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerPlanCore

  @moduletag :fast
  @moduletag :security_regression

  @digest String.duplicate("a", 64)
  @init_digest String.duplicate("b", 64)
  @image "127.0.0.1:0/arbor/workload@sha256:#{@digest}"
  @init_image "127.0.0.1:0/arbor/vminit@sha256:#{@init_digest}"
  @kernel_path "/usr/local/share/container/kernels/default.kernel"
  @name "arbor-val-unit01"

  # Plan projections are host bind sources only — no host :tmp.
  @projections %{
    worktree: "/private/tmp/arbor-val/worktree",
    home: "/private/tmp/arbor-val/home",
    build: "/private/tmp/arbor-val/build",
    deps: "/private/tmp/arbor-val/deps",
    validation_runner: "/private/tmp/arbor-val/runner",
    validation_result: "/private/tmp/arbor-val/result",
    mix_wrapper_dir: "/private/tmp/arbor-val/bin"
  }

  # Host tmp path used only to prove it never enters the Apple plan.
  @host_tmp_path "/private/tmp/arbor-val/tmp"

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
    init_image: @init_image,
    kernel_path: @kernel_path,
    name: @name,
    projections: @projections,
    host_runtime_roots: @host_runtime_roots_valid,
    mix_env: "test",
    command_args: ["test", "apps/arbor_shell/test/example_test.exs"],
    resource_profile: :standard
  }

  # Invalid UTF-8 binary (lone continuation byte) — must never raise.
  @invalid_utf8 <<0xC3, 0x28>>

  describe "positive exact create plan" do
    test "builds full containment argv with image-owned archives and fixed execution policy" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)

      assert plan.runtime_executable == "/usr/local/bin/container"
      assert plan.unit_name == @name
      assert plan.image == @image
      assert plan.init_image == @init_image
      assert plan.kernel_path == @kernel_path
      assert plan.platform == "linux/arm64"
      assert plan.runtime_handler == "container-runtime-linux"
      assert plan.registry_scheme == "https"
      assert plan.mix_env == "test"
      assert plan.command_args == ["test", "apps/arbor_shell/test/example_test.exs"]
      assert plan.guest_workdir == "/workspace"
      assert plan.guest_mix_wrapper == "/arbor/bin/mix"

      assert plan.guest_runtime_roots == %{
               erlang: "/usr/local/lib/erlang",
               elixir: "/usr/local"
             }

      assert plan.guest_mix_home == "/usr/local/.mix"
      assert plan.guest_mix_archives == "/usr/local/.mix/archives"
      assert plan.guest_elixir_make_cache == "/usr/local/.cache/elixir_make"

      assert plan.resource_profile == :standard
      assert plan.resource_limits == %{cpus: "1", memory: "2G"}
      assert plan.lifecycle.preflight_order == [:verify_absent]
      assert plan.lifecycle.start_order == [:create, :start]
      assert plan.lifecycle.terminal_order == [:force_stop, :delete, :verify_absent]

      create = plan.argv.create

      assert create ==
               [
                 "/usr/local/bin/container",
                 "create",
                 "--name",
                 @name,
                 "--platform",
                 "linux/arm64",
                 "--runtime",
                 "container-runtime-linux",
                 "--kernel",
                 @kernel_path,
                 "--init-image",
                 @init_image,
                 "--scheme",
                 "https",
                 "--network",
                 "none",
                 "--no-dns",
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
                 "type=bind,source=/private/tmp/arbor-val/build,target=/arbor/build",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/deps,target=/arbor/deps",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/runner,target=/arbor/validation/runner,readonly",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/result,target=/arbor/validation/result",
                 "--mount",
                 "type=bind,source=/private/tmp/arbor-val/bin,target=/arbor/bin,readonly",
                 "--tmpfs",
                 "/tmp",
                 "--workdir",
                 "/workspace",
                 "--env",
                 "HOME=/arbor/home",
                 "--env",
                 "TMPDIR=/tmp",
                 "--env",
                 "MIX_BUILD_PATH=/arbor/build",
                 "--env",
                 "MIX_DEPS_PATH=/arbor/deps",
                 "--env",
                 "MIX_HOME=/usr/local/.mix",
                 "--env",
                 "MIX_ARCHIVES=/usr/local/.mix/archives",
                 "--env",
                 "ELIXIR_MAKE_CACHE_DIR=/usr/local/.cache/elixir_make",
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
               "--force",
               @name
             ]

      assert plan.argv.verify_absent == [
               "/usr/local/bin/container",
               "list",
               "--all",
               "--format",
               "json"
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

      # Host tmp is not a plan projection and never appears in plan data/argv.
      refute Map.has_key?(plan.projections, :tmp)
      refute Map.has_key?(plan.projections, "tmp")
      refute String.contains?(create_joined, @host_tmp_path)
      refute String.contains?(inspect(plan), @host_tmp_path)
      refute Enum.any?(create, &String.contains?(&1, "type=tmpfs"))
      # Bind mounts never target guest /tmp; only the dedicated --tmpfs path token is /tmp.
      refute Enum.any?(create, &String.contains?(&1, "target=/tmp"))

      assert plan.guest_tmpfs == %{
               guest_path: "/tmp",
               argv_spec: "/tmp"
             }

      # Exactly one dedicated path-only --tmpfs option.
      tmpfs_flag_indexes =
        create
        |> Enum.with_index()
        |> Enum.filter(fn {token, _} -> token == "--tmpfs" end)
        |> Enum.map(fn {_, idx} -> idx end)

      assert length(tmpfs_flag_indexes) == 1
      [tmpfs_idx] = tmpfs_flag_indexes
      assert Enum.at(create, tmpfs_idx + 1) == "/tmp"
      # No Docker-style size/mode options on the path token.
      refute String.contains?(Enum.at(create, tmpfs_idx + 1), "size=")
      refute String.contains?(Enum.at(create, tmpfs_idx + 1), "mode=")

      # Mounts are host-source binds only.
      assert Enum.map(plan.mounts, & &1.guest_path) == [
               "/workspace",
               "/arbor/home",
               "/arbor/build",
               "/arbor/deps",
               "/arbor/validation/runner",
               "/arbor/validation/result",
               "/arbor/bin"
             ]

      assert Enum.map(plan.mounts, & &1.mode) == [
               :read_write,
               :read_write,
               :read_write,
               :read_write,
               :read_only,
               :read_write,
               :read_only
             ]

      assert Enum.all?(plan.mounts, &is_binary(&1.host_path))
      refute Enum.any?(plan.mounts, &(&1.purpose == :tmp))
      refute Enum.any?(plan.mounts, &(&1.guest_path == "/tmp"))

      # Runtime parent is not a mount purpose — only typed children + worktree/deps/wrapper.
      refute Enum.any?(plan.mounts, &(&1.purpose == :runtime))
      refute Enum.any?(plan.mounts, &(&1.guest_path == "/arbor/runtime"))
      refute Map.has_key?(plan.projections, :runtime)

      refute_forbidden_tokens(plan)
    end

    test "is deterministic for the same request" do
      assert {:ok, a} = AppleContainerPlanCore.new(@valid_request)
      assert {:ok, b} = AppleContainerPlanCore.new(@valid_request)
      assert a == b
      assert AppleContainerPlanCore.show(a) == AppleContainerPlanCore.show(b)
    end

    test "show exposes JSON-clean infrastructure fields as local execution aliases" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      shown = AppleContainerPlanCore.show(plan)

      assert shown["image"] == @image
      assert shown["image_kind"] == "local_execution_alias"
      assert shown["init_image"] == @init_image
      assert shown["init_image_kind"] == "local_execution_alias"
      assert shown["kernel_path"] == @kernel_path
      assert shown["platform"] == "linux/arm64"
      assert shown["runtime_handler"] == "container-runtime-linux"
      assert shown["registry_scheme"] == "https"
      assert shown["guest_mix_home"] == "/usr/local/.mix"
      assert shown["guest_mix_archives"] == "/usr/local/.mix/archives"
      assert shown["guest_elixir_make_cache"] == "/usr/local/.cache/elixir_make"

      assert shown["guest_tmpfs"] == %{
               "guest_path" => "/tmp",
               "argv_spec" => "/tmp"
             }

      assert shown["resource_profile"] == "standard"
      assert shown["resource_limits"] == %{"cpus" => "1", "memory" => "2G"}

      refute Map.has_key?(shown["projections"], "tmp")
      refute Enum.any?(shown["mounts"], &(&1["purpose"] == "tmp"))
      refute Enum.any?(shown["mounts"], &(&1["guest_path"] == "/tmp"))
      refute String.contains?(Jason.encode!(shown), @host_tmp_path)
      assert "--tmpfs" in shown["argv"]["create"]
      assert "/tmp" in shown["argv"]["create"]

      assert shown["argv"]["create"] == plan.argv.create
      assert Jason.encode!(shown)
    end

    test "accepts string-keyed request maps" do
      request = %{
        "image" => @image,
        "init_image" => @init_image,
        "kernel_path" => @kernel_path,
        "name" => @name,
        "projections" => %{
          "worktree" => @projections.worktree,
          "home" => @projections.home,
          "build" => @projections.build,
          "deps" => @projections.deps,
          "mix_wrapper_dir" => @projections.mix_wrapper_dir
        },
        "host_runtime_roots" => %{
          "erlang" => @host_runtime_roots_valid.erlang,
          "elixir" => @host_runtime_roots_valid.elixir
        },
        "mix_env" => "prod",
        "command_args" => ["compile"],
        "resource_profile" => :standard
      }

      assert {:ok, plan} = AppleContainerPlanCore.new(request)
      assert plan.mix_env == "prod"
      assert plan.resource_profile == :standard
      assert plan.init_image == @init_image
      assert plan.kernel_path == @kernel_path
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
        :init_image,
        :kernel_path,
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
      other_workload = "127.0.0.1:0/arbor/workload@sha256:#{String.duplicate("c", 64)}"
      other_init = "127.0.0.1:0/arbor/vminit@sha256:#{String.duplicate("d", 64)}"

      request =
        @valid_request
        |> Map.put(:image, @image)
        |> Map.put("image", other_workload)

      assert {:error, {:duplicate_request_key_alias, :image}} =
               AppleContainerPlanCore.new(request)

      request =
        @valid_request
        |> Map.put(:init_image, @init_image)
        |> Map.put("init_image", other_init)

      assert {:error, {:duplicate_request_key_alias, :init_image}} =
               AppleContainerPlanCore.new(request)

      request =
        @valid_request
        |> Map.put(:kernel_path, @kernel_path)
        |> Map.put("kernel_path", "/other/kernel")

      assert {:error, {:duplicate_request_key_alias, :kernel_path}} =
               AppleContainerPlanCore.new(request)
    end
  end

  describe "invalid UTF-8 fail-closed" do
    @tag :security_regression
    test "table: every accepted textual input path rejects invalid UTF-8 without raising" do
      cases = [
        {:image, Map.put(@valid_request, :image, @invalid_utf8)},
        {:init_image, Map.put(@valid_request, :init_image, @invalid_utf8)},
        {:kernel_path, Map.put(@valid_request, :kernel_path, "/private/tmp/" <> @invalid_utf8)},
        {:name, Map.put(@valid_request, :name, @invalid_utf8)},
        {:mix_env, Map.put(@valid_request, :mix_env, @invalid_utf8)},
        {:command_args, Map.put(@valid_request, :command_args, ["test", @invalid_utf8])},
        {:projection_worktree,
         Map.put(
           @valid_request,
           :projections,
           Map.put(@projections, :worktree, "/private/tmp/" <> @invalid_utf8)
         )},
        {:projection_mix_wrapper_dir,
         Map.put(
           @valid_request,
           :projections,
           Map.put(@projections, :mix_wrapper_dir, "/private/tmp/mix" <> @invalid_utf8)
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
                    elem(reason, 0) in [
                      :invalid_projection,
                      :invalid_host_runtime_root,
                      :invalid_kernel_path
                    ] and
                    elem(reason, tuple_size(reason) - 1) == :invalid_utf8),
               "label=#{inspect(label)} got #{inspect(reason)}, expected :invalid_utf8 envelope"
      end
    end
  end

  describe "local execution alias admission" do
    @tag :security_regression
    test "admits only exact workload and vminit local execution aliases" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      assert plan.image == @image
      assert plan.init_image == @init_image
      assert @image in plan.argv.create
      assert @init_image in plan.argv.create

      # Wrong role under the local sink.
      assert {:error, :wrong_execution_alias_role} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :image, @init_image))

      assert {:error, :wrong_execution_alias_role} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :init_image, @image))
    end

    @tag :security_regression
    test "rejects equal workload/vminit index digests even when roles differ" do
      same_digest = String.duplicate("e", 64)
      workload = "127.0.0.1:0/arbor/workload@sha256:#{same_digest}"
      init = "127.0.0.1:0/arbor/vminit@sha256:#{same_digest}"

      request =
        @valid_request
        |> Map.put(:image, workload)
        |> Map.put(:init_image, init)

      assert {:error, :identical_workload_and_init_index_digests} =
               AppleContainerPlanCore.new(request)
    end

    @tag :security_regression
    test "create argv never contains external provisioning references" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      create = plan.argv.create
      joined = Enum.join(create, " ")
      all_tokens = plan.argv |> Map.values() |> List.flatten()

      refute_external_provisioning_refs(create)
      refute_external_provisioning_refs(all_tokens)

      # Digest-bearing tokens must be exactly the two local execution aliases.
      digest_tokens = Enum.filter(all_tokens, &String.contains?(&1, "@sha256:"))
      assert Enum.sort(digest_tokens) == Enum.sort([@image, @init_image])

      # Workload alias is the sole post-entrypoint image token; init is only
      # under --init-image.
      init_idx = Enum.find_index(create, &(&1 == "--init-image"))
      assert is_integer(init_idx)
      assert Enum.at(create, init_idx + 1) == @init_image

      ep_idx = Enum.find_index(create, &(&1 == "--entrypoint"))
      assert Enum.at(create, ep_idx + 2) == @image

      refute String.contains?(joined, "docker.io")
      refute String.contains?(joined, "ghcr.io")
      refute String.contains?(joined, "registry.example.com")
      refute String.contains?(joined, "quay.io")
      refute String.contains?(joined, "gcr.io")
    end
  end

  describe "image rejection" do
    @tag :security_regression
    test "table: tag-only, external, wrong host/port/repo/role, uppercase, malformed, option-shaped" do
      cases = [
        {"alpine:latest", :mutable_image_tag},
        {"docker.io/arbor/validation:v1", :mutable_image_tag},
        {"docker.io/arbor/validation", :mutable_image_tag},
        {"docker.io/arbor/workload@sha256:#{@digest}", :external_provisioning_reference},
        {"ghcr.io/arbor/workload@sha256:#{@digest}", :external_provisioning_reference},
        {"registry.example.com:5000/arbor/workload@sha256:#{@digest}",
         :external_provisioning_reference},
        {"quay.io/arbor/workload@sha256:#{@digest}", :external_provisioning_reference},
        {"localhost/arbor/workload@sha256:#{@digest}", :external_provisioning_reference},
        {"127.0.0.1:1/arbor/workload@sha256:#{@digest}", :external_provisioning_reference},
        {"127.0.0.1/arbor/workload@sha256:#{@digest}", :not_local_execution_alias},
        {"127.0.0.1:0/arbor/validation@sha256:#{@digest}", :not_local_execution_alias},
        {"127.0.0.1:0/other/workload@sha256:#{@digest}", :not_local_execution_alias},
        {"127.0.0.1:0/arbor/workload:latest", :mutable_image_tag},
        {"127.0.0.1:0/arbor/workload@sha256:#{String.upcase(@digest)}", :uppercase_image_digest},
        {"127.0.0.1:0/arbor/workload@SHA256:#{@digest}", :uppercase_image_digest},
        {"127.0.0.1:0/arbor/workload@sha256:abcd", :malformed_image_digest},
        {"127.0.0.1:0/arbor/workload@sha256:#{String.duplicate("g", 64)}",
         :malformed_image_digest},
        {"127.0.0.1:0/arbor/workload@sha256:#{String.duplicate("a", 63)}",
         :malformed_image_digest},
        {"127.0.0.1:0/arbor/workload@sha256:#{String.duplicate("a", 65)}",
         :malformed_image_digest},
        {"127.0.0.1:0/arbor/workload@sha256:#{@digest}?pull=1", :malformed_image},
        {"127.0.0.1:0/arbor/workload@sha256:#{@digest}#frag", :malformed_image},
        {"arbor/workload@sha256:#{@digest}", :not_local_execution_alias},
        {"registry/arbor/workload@sha256:#{@digest}", :not_local_execution_alias},
        {"127.0.0.1:0/arbor/workload @sha256:#{@digest}", :unsafe_image},
        {"127.0.0.1:0/arbor/workload@sha256:#{@digest}\n", :unsafe_image},
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
                   :invalid_image,
                   :not_local_execution_alias,
                   :external_provisioning_reference,
                   :wrong_execution_alias_role
                 ],
               "image=#{inspect(image)} got #{inspect(reason)}, expected ~#{inspect(expected)}"
      end
    end

    @tag :security_regression
    test "rejects externally routable fully-qualified provisioning references" do
      external_refs = [
        "registry.example.com:5000/arbor/validation@sha256:#{@digest}",
        "docker.io/arbor/validation@sha256:#{@digest}",
        "ghcr.io/other/image@sha256:#{@digest}",
        "https://registry.example.com/arbor/workload@sha256:#{@digest}"
      ]

      for image <- external_refs do
        assert {:error, reason} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :image, image))

        assert reason in [
                 :external_provisioning_reference,
                 :not_local_execution_alias,
                 :malformed_image
               ],
               "image=#{inspect(image)} got #{inspect(reason)}"

        # Failure happens before argv construction — no plan, no leak into argv.
        refute match?(
                 {:ok, _},
                 AppleContainerPlanCore.new(Map.put(@valid_request, :image, image))
               )
      end
    end
  end

  describe "init image rejection" do
    @tag :security_regression
    test "requires distinct local vminit execution alias" do
      assert {:error, :missing_init_image} =
               AppleContainerPlanCore.new(Map.delete(@valid_request, :init_image))

      # Workload alias is the wrong role for init_image.
      assert {:error, :wrong_execution_alias_role} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :init_image, @image))

      cases = [
        {"alpine:latest", :mutable_image_tag},
        {"arbor/vminit@sha256:#{@init_digest}", :not_local_execution_alias},
        {"registry/arbor/vminit@sha256:#{@init_digest}", :not_local_execution_alias},
        {"docker.io/arbor/vminit@sha256:#{@init_digest}", :external_provisioning_reference},
        {"127.0.0.1:0/arbor/vminit@sha256:#{String.upcase(@init_digest)}",
         :uppercase_image_digest},
        {"127.0.0.1:0/arbor/vminit@sha256:abcd", :malformed_image_digest},
        {"127.0.0.1:0/arbor/workload@sha256:#{@init_digest}", :wrong_execution_alias_role},
        {"127.0.0.1:0/arbor/vminit@sha256:#{@init_digest}?x=1", :malformed_image},
        {"", :empty_image}
      ]

      for {init_image, expected} <- cases do
        assert {:error, reason} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :init_image, init_image))

        assert reason == expected,
               "init_image=#{inspect(init_image)} got #{inspect(reason)}, expected #{inspect(expected)}"
      end
    end
  end

  describe "kernel path rejection" do
    @tag :security_regression
    test "requires absolute canonical kernel path outside all projections" do
      assert {:error, :missing_kernel_path} =
               AppleContainerPlanCore.new(Map.delete(@valid_request, :kernel_path))

      cases = [
        {"relative/kernel", :relative_path},
        {"/tmp/./kernel", :dot_segment},
        {"/tmp/foo/../kernel", :dot_segment},
        {"/tmp//kernel", :non_canonical_path},
        {"/tmp/kernel/", :trailing_slash},
        {"/tmp/ker\0nel", :nul_byte},
        {"/tmp/ker\nnel", :control_char},
        {"/tmp/ker nel", :whitespace_in_path},
        {"", :empty_path}
      ]

      for {path, expected_reason} <- cases do
        assert {:error, {:invalid_kernel_path, ^expected_reason}} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :kernel_path, path)),
               "kernel_path=#{inspect(path)} expected #{inspect(expected_reason)}"
      end

      # Equal to a projection host path.
      assert {:error, {:kernel_path_overlaps_projection, :worktree}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :kernel_path, @projections.worktree)
               )

      # Descendant of a candidate-owned projection.
      under_worktree = @projections.worktree <> "/kernels/default"

      assert {:error, {:kernel_path_overlaps_projection, :worktree}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :kernel_path, under_worktree))

      # Ancestor of a projection path must fail closed.
      assert {:error, {:kernel_path_overlaps_projection, purpose}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :kernel_path, "/private/tmp/arbor-val")
               )

      assert purpose in [
               :worktree,
               :home,
               :build,
               :deps,
               :validation_runner,
               :validation_result,
               :mix_wrapper_dir
             ]

      # Sibling outside projections is accepted.
      sibling = "/private/tmp/arbor-val-kernels/default.kernel"

      assert {:ok, plan} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :kernel_path, sibling))

      assert plan.kernel_path == sibling
      assert "--kernel" in plan.argv.create
      assert sibling in plan.argv.create
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
        {{:build, "/tmp//double"}, :non_canonical_path},
        {{:deps, "/tmp/deps/"}, :trailing_slash},
        {{:home, "/tmp/ho\0me"}, :nul_byte},
        {{:mix_wrapper_dir, "/tmp/mix\nwrapper"}, :control_char},
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
      # Read/write worktree must never contain the read-only wrapper directory source.
      nested_wrapper =
        Map.put(
          @projections,
          :mix_wrapper_dir,
          @projections.worktree <> "/bin"
        )

      assert {:error, {:overlapping_projection_paths, a, b}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_wrapper))

      assert MapSet.new([a, b]) == MapSet.new([:worktree, :mix_wrapper_dir])

      # Reverse order of nesting: worktree under home (both read/write — must not nest).
      nested_worktree =
        @projections
        |> Map.put(:home, "/private/tmp/arbor-val/base")
        |> Map.put(:worktree, "/private/tmp/arbor-val/base/worktree")

      assert {:error, {:overlapping_projection_paths, c, d}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_worktree))

      assert MapSet.new([c, d]) == MapSet.new([:home, :worktree])

      # Read/write roots must not nest either direction (deps under build).
      nested_deps =
        @projections
        |> Map.put(:build, "/private/tmp/arbor-val/build-root")
        |> Map.put(:deps, "/private/tmp/arbor-val/build-root/deps")

      assert {:error, {:overlapping_projection_paths, e, f}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_deps))

      assert MapSet.new([e, f]) == MapSet.new([:build, :deps])

      # Opposite nesting direction (build under deps).
      nested_build =
        @projections
        |> Map.put(:deps, "/private/tmp/arbor-val/deps-root")
        |> Map.put(:build, "/private/tmp/arbor-val/deps-root/build")

      assert {:error, {:overlapping_projection_paths, g, h}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested_build))

      assert MapSet.new([g, h]) == MapSet.new([:deps, :build])

      # Every host bind projection pair remains subject to overlap rejection.
      projection_purposes = [
        :worktree,
        :home,
        :build,
        :deps,
        :validation_runner,
        :validation_result,
        :mix_wrapper_dir
      ]

      for parent <- projection_purposes, child <- projection_purposes, parent != child do
        nested =
          @projections
          |> Map.put(parent, "/private/tmp/arbor-val/overlap-parent")
          |> Map.put(child, "/private/tmp/arbor-val/overlap-parent/child")

        assert {:error, {:overlapping_projection_paths, x, y}} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :projections, nested))

        assert MapSet.new([x, y]) == MapSet.new([parent, child])
      end

      # Host :tmp is not an accepted plan projection key.
      with_tmp = Map.put(@projections, :tmp, @host_tmp_path)

      assert {:error, :unsupported_projection_keys} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, with_tmp))
    end

    @tag :security_regression
    test "rejects extra runtime projection key and common runtime parent of home/tmp/build" do
      # Runtime is not a projection purpose: extra key fails closed.
      with_runtime = Map.put(@projections, :runtime, "/private/tmp/arbor-val/runtime")

      assert {:error, :unsupported_projection_keys} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, with_runtime))

      with_runtime_string =
        @projections
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
        |> Map.put("runtime", "/private/tmp/arbor-val/runtime")

      assert {:error, :unsupported_projection_keys} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :projections, with_runtime_string)
               )

      # No mount source may be the common parent of home/build/deps (runtime parent shape).
      # Using worktree as that parent would expose runner/result-style siblings if present.
      common_parent = "/private/tmp/arbor-val/revision-runtime"

      parent_as_worktree =
        @projections
        |> Map.put(:worktree, common_parent)
        |> Map.put(:home, common_parent <> "/home")
        |> Map.put(:build, common_parent <> "/build")
        |> Map.put(:deps, common_parent <> "/deps")

      assert {:error, {:overlapping_projection_paths, a, b}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :projections, parent_as_worktree)
               )

      assert MapSet.new([a, b])
             |> MapSet.intersection(MapSet.new([:worktree, :home, :build, :deps]))
             |> MapSet.size() == 2

      # Same common parent assigned to deps while nesting home/build.
      parent_as_deps =
        @projections
        |> Map.put(:deps, common_parent)
        |> Map.put(:home, common_parent <> "/home")
        |> Map.put(:build, common_parent <> "/build")

      assert {:error, {:overlapping_projection_paths, c, d}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, parent_as_deps))

      assert MapSet.new([c, d])
             |> MapSet.intersection(MapSet.new([:deps, :home, :build]))
             |> MapSet.size() == 2

      # Successful plan mounts only host bind sources; never host tmp path.
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      bind_sources = Enum.map(plan.mounts, & &1.host_path)
      refute @host_tmp_path in bind_sources
      refute String.contains?(inspect(plan), @host_tmp_path)

      for source <- bind_sources do
        children = [@projections.home, @projections.build, @projections.deps]

        ancestor_of_all? =
          Enum.all?(children, fn child ->
            child == source or String.starts_with?(child, source <> "/")
          end)

        refute ancestor_of_all?,
               "mount source #{inspect(source)} must not be common parent of home/build/deps"
      end
    end

    @tag :security_regression
    test "table: allows sibling path-prefix near misses (not raw String.starts_with?)" do
      cases = [
        {:worktree, "/private/tmp/arbor-val/work", :home, "/private/tmp/arbor-val/worktree"},
        {:mix_wrapper_dir, "/private/tmp/arbor-val/bin", :worktree,
         "/private/tmp/arbor-val/binary-worktree"}
      ]

      for {key_a, path_a, key_b, path_b} <- cases do
        sibling =
          @projections
          |> Map.put(key_a, path_a)
          |> Map.put(key_b, path_b)

        assert {:ok, plan} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, :projections, sibling))

        assert Map.fetch!(plan.projections, key_a) == path_a
        assert Map.fetch!(plan.projections, key_b) == path_b
      end
    end

    test "rejects the retired file-shaped wrapper projection key" do
      file_shaped =
        @projections
        |> Map.delete(:mix_wrapper_dir)
        |> Map.put(:mix_wrapper, "/private/tmp/arbor-val/bin/mix")

      assert {:error, :unsupported_projection_keys} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :projections, file_shaped))
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

    @tag :security_regression
    test "rejects caller control of guest tmpfs path, size, or mode" do
      for key <- [
            :tmpfs,
            :tmpfs_size,
            :tmpfs_path,
            :tmpfs_mode,
            :guest_tmp,
            :guest_tmpfs,
            :guest_tmp_path,
            :guest_tmpfs_size,
            :guest_tmpfs_mode,
            "tmpfs",
            "tmpfs_size",
            "guest_tmpfs"
          ] do
        assert {:error, {:unsupported_request_keys, _}} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, key, "/evil-tmp")),
               "expected rejection for caller tmpfs key #{inspect(key)}"
      end

      # Successful create always uses the fixed dedicated path-only --tmpfs grammar.
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      create = plan.argv.create

      assert Enum.count(create, &(&1 == "--tmpfs")) == 1
      tmpfs_idx = Enum.find_index(create, &(&1 == "--tmpfs"))
      assert Enum.at(create, tmpfs_idx + 1) == "/tmp"
      refute Enum.any?(create, &String.contains?(&1, "type=tmpfs"))
      refute Enum.any?(create, &String.contains?(&1, "size="))
      refute Enum.any?(create, &String.contains?(&1, "mode="))
      refute String.contains?(Enum.join(create, " "), @host_tmp_path)
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

    @tag :security_regression
    test "rejects caller overrides of platform/runtime/scheme/DNS/network and related flags" do
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
            :memory,
            :platform,
            :runtime,
            :runtime_handler,
            :scheme,
            :registry_scheme,
            :dns,
            :no_dns,
            :kernel,
            :init
          ] do
        assert {:error, {:unsupported_request_keys, _}} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, key, "attacker-value")),
               "expected rejection for caller key #{inspect(key)}"
      end

      # Successful plan hard-codes infrastructure; request cannot change them.
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      create = plan.argv.create

      assert plan.platform == "linux/arm64"
      assert plan.runtime_handler == "container-runtime-linux"
      assert plan.registry_scheme == "https"

      platform_idx = Enum.find_index(create, &(&1 == "--platform"))
      runtime_idx = Enum.find_index(create, &(&1 == "--runtime"))
      scheme_idx = Enum.find_index(create, &(&1 == "--scheme"))
      network_idx = Enum.find_index(create, &(&1 == "--network"))

      assert Enum.at(create, platform_idx + 1) == "linux/arm64"
      assert Enum.at(create, runtime_idx + 1) == "container-runtime-linux"
      assert Enum.at(create, scheme_idx + 1) == "https"
      assert Enum.at(create, network_idx + 1) == "none"
      assert "--no-dns" in create

      # Only one of each management flag.
      assert Enum.count(create, &(&1 == "--platform")) == 1
      assert Enum.count(create, &(&1 == "--runtime")) == 1
      assert Enum.count(create, &(&1 == "--scheme")) == 1
      assert Enum.count(create, &(&1 == "--network")) == 1
      assert Enum.count(create, &(&1 == "--no-dns")) == 1
    end
  end

  describe "cleanup breadth and forbidden tokens" do
    test "cleanup argv targets only the exact unit name" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)

      for key <- [:force_stop, :delete] do
        argv = Map.fetch!(plan.argv, key)
        assert @name in argv
        refute "-a" in argv
        refute Enum.any?(argv, &String.contains?(&1, "*"))
        # Exact ID only — no filter expressions.
        refute Enum.any?(argv, &String.contains?(&1, "name="))
      end

      assert plan.argv.delete == [
               "/usr/local/bin/container",
               "delete",
               "--force",
               @name
             ]

      # Positive absence uses list --all JSON (unit match is pure-core side).
      assert plan.argv.verify_absent == [
               "/usr/local/bin/container",
               "list",
               "--all",
               "--format",
               "json"
             ]

      refute @name in plan.argv.verify_absent

      # Delete is not --rm create; create never carries --rm.
      refute "--rm" in plan.argv.create
      refute "--remove" in plan.argv.create
    end

    test "positive plan never includes publish, ssh, env-file, privileged, or --rm/--all" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      refute_forbidden_tokens(plan)
    end

    test "relative tool is pure preflight before admission" do
      # Pure preflight only — no host Apple Container dependency.
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
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
      assert Enum.count(create, &(&1 == "--entrypoint")) == 1
      assert Enum.at(create, ep_idx + 1) == "/arbor/bin/mix"

      image_index = Enum.find_index(create, &(&1 == @image))
      assert is_integer(image_index)
      assert image_index == ep_idx + 2

      # After the image token: only caller command_args (empty here).
      assert Enum.drop(create, image_index + 1) == []

      # Exactly one /arbor/bin/mix token (entrypoint value), never a second post-image token.
      assert Enum.count(create, &(&1 == "/arbor/bin/mix")) == 1

      # Infrastructure management options appear before the workload image.
      for flag <- [
            "--platform",
            "--runtime",
            "--kernel",
            "--init-image",
            "--scheme",
            "--network",
            "--no-dns"
          ] do
        flag_idx = Enum.find_index(create, &(&1 == flag))
        assert is_integer(flag_idx)
        assert flag_idx < image_index
      end
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

  describe "closed resource profiles" do
    test "explicit standard profile produces 1 CPU / 2G plan and create argv" do
      assert {:ok, plan} = AppleContainerPlanCore.new(@valid_request)
      assert plan.resource_profile == :standard
      assert plan.resource_limits == %{cpus: "1", memory: "2G"}

      create = plan.argv.create
      cpus_idx = Enum.find_index(create, &(&1 == "--cpus"))
      memory_idx = Enum.find_index(create, &(&1 == "--memory"))
      assert Enum.at(create, cpus_idx + 1) == "1"
      assert Enum.at(create, memory_idx + 1) == "2G"
      assert Enum.count(create, &(&1 == "--cpus")) == 1
      assert Enum.count(create, &(&1 == "--memory")) == 1
    end

    test "intensive profile produces 4 CPU / 4G in plan and create argv" do
      assert {:ok, plan} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :resource_profile, :intensive))

      assert plan.resource_profile == :intensive
      assert plan.resource_limits == %{cpus: "4", memory: "4G"}

      create = plan.argv.create
      cpus_idx = Enum.find_index(create, &(&1 == "--cpus"))
      memory_idx = Enum.find_index(create, &(&1 == "--memory"))
      assert Enum.at(create, cpus_idx + 1) == "4"
      assert Enum.at(create, memory_idx + 1) == "4G"
    end

    test "show reports selected profile and mapped limits" do
      assert {:ok, standard} = AppleContainerPlanCore.new(@valid_request)
      shown_standard = AppleContainerPlanCore.show(standard)
      assert shown_standard["resource_profile"] == "standard"
      assert shown_standard["resource_limits"] == %{"cpus" => "1", "memory" => "2G"}

      assert {:ok, intensive} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :resource_profile, :intensive))

      shown_intensive = AppleContainerPlanCore.show(intensive)
      assert shown_intensive["resource_profile"] == "intensive"
      assert shown_intensive["resource_limits"] == %{"cpus" => "4", "memory" => "4G"}
      assert Jason.encode!(shown_intensive)
    end

    @tag :security_regression
    test "security regression: missing profile and raw/string/map overrides fail closed" do
      # PlanCore requires an explicit profile — facade defaulting is not here.
      assert {:error, :missing_resource_profile} =
               AppleContainerPlanCore.new(Map.delete(@valid_request, :resource_profile))

      # Unknown atoms, strings, maps, integers, booleans, and nil all fail closed.
      for bad <- [
            :turbo,
            :standard_plus,
            :high,
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
                 AppleContainerPlanCore.new(Map.put(@valid_request, :resource_profile, bad)),
               "expected rejection for profile #{inspect(bad)}"
      end

      # Raw limit keys and open resource maps remain outside the closed surface.
      for key <- [:cpus, :memory, :resource_limits, :resources] do
        assert {:error, {:unsupported_request_keys, _}} =
                 AppleContainerPlanCore.new(Map.put(@valid_request, key, "4")),
               "expected rejection for open key #{inspect(key)}"
      end

      assert {:error, {:unsupported_request_keys, _}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :cpus, "99"))

      assert {:error, {:unsupported_request_keys, _}} =
               AppleContainerPlanCore.new(Map.put(@valid_request, :memory, "99G"))

      assert {:error, {:unsupported_request_keys, _}} =
               AppleContainerPlanCore.new(
                 Map.put(@valid_request, :resource_limits, %{cpus: "4", memory: "4G"})
               )

      # Duplicate atom/string aliases for the closed selector fail closed.
      assert {:error, {:duplicate_request_key_alias, :resource_profile}} =
               AppleContainerPlanCore.new(
                 @valid_request
                 |> Map.put(:resource_profile, :intensive)
                 |> Map.put("resource_profile", :intensive)
               )
    end
  end

  describe "constants surface" do
    test "exports fixed executable, guest mounts, infrastructure, and resource limits" do
      assert AppleContainerPlanCore.runtime_executable() == "/usr/local/bin/container"
      assert AppleContainerPlanCore.platform() == "linux/arm64"
      assert AppleContainerPlanCore.runtime_handler() == "container-runtime-linux"
      assert AppleContainerPlanCore.registry_scheme() == "https"

      # Bind table is host sources only — guest tmp is private dedicated tmpfs.
      assert AppleContainerPlanCore.guest_mount_table() == [
               {:worktree, "/workspace", :read_write},
               {:home, "/arbor/home", :read_write},
               {:build, "/arbor/build", :read_write},
               {:deps, "/arbor/deps", :read_write},
               {:validation_runner, "/arbor/validation/runner", :read_only},
               {:validation_result, "/arbor/validation/result", :read_write},
               {:mix_wrapper_dir, "/arbor/bin", :read_only}
             ]

      assert AppleContainerPlanCore.guest_validation_runner_script() ==
               "/arbor/validation/runner/runner.exs"

      assert AppleContainerPlanCore.guest_validation_result_file() ==
               "/arbor/validation/result/reviewed_regression_evidence"

      assert Shell.guest_validation_runner_script() ==
               AppleContainerPlanCore.guest_validation_runner_script()

      assert Shell.validation_result_basename() == "reviewed_regression_evidence"

      assert AppleContainerPlanCore.guest_tmpfs() == %{
               guest_path: "/tmp",
               argv_spec: "/tmp"
             }

      assert AppleContainerPlanCore.guest_runtime_roots() == %{
               erlang: "/usr/local/lib/erlang",
               elixir: "/usr/local"
             }

      # Standard diagnostic API plus total profile policy (never raises).
      assert AppleContainerPlanCore.default_resource_profile() == :standard
      assert AppleContainerPlanCore.resource_limits() == %{cpus: "1", memory: "2G"}

      assert {:ok, :standard} = AppleContainerPlanCore.normalize_resource_profile(:standard)
      assert {:ok, :intensive} = AppleContainerPlanCore.normalize_resource_profile(:intensive)

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.normalize_resource_profile(:turbo)

      # Request-time contract remains atom-only; strings fail closed.
      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.normalize_resource_profile("standard")

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.normalize_resource_profile(%{cpus: "4"})

      # Durable re-admission admits atoms and the exact JSON-clean show/1 forms.
      assert {:ok, :standard} =
               AppleContainerPlanCore.normalize_durable_resource_profile(:standard)

      assert {:ok, :intensive} =
               AppleContainerPlanCore.normalize_durable_resource_profile(:intensive)

      assert {:ok, :standard} =
               AppleContainerPlanCore.normalize_durable_resource_profile("standard")

      assert {:ok, :intensive} =
               AppleContainerPlanCore.normalize_durable_resource_profile("intensive")

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.normalize_durable_resource_profile(:turbo)

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.normalize_durable_resource_profile("turbo")

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.normalize_durable_resource_profile("Standard")

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.normalize_durable_resource_profile(%{cpus: "4"})

      assert {:ok, %{cpus: "1", memory: "2G"}} =
               AppleContainerPlanCore.resource_limits_for(:standard)

      assert {:ok, %{cpus: "4", memory: "4G"}} =
               AppleContainerPlanCore.resource_limits_for(:intensive)

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.resource_limits_for(:turbo)

      assert {:error, :invalid_resource_profile} =
               AppleContainerPlanCore.resource_limits_for("intensive")

      assert AppleContainerPlanCore.allowed_mix_envs() == ["dev", "prod", "test"]
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp refute_external_provisioning_refs(tokens) when is_list(tokens) do
    for token <- tokens do
      refute String.starts_with?(token, "docker.io/"),
             "external docker.io ref in argv: #{inspect(token)}"

      refute String.starts_with?(token, "ghcr.io/"),
             "external ghcr.io ref in argv: #{inspect(token)}"

      refute String.starts_with?(token, "quay.io/"),
             "external quay.io ref in argv: #{inspect(token)}"

      refute String.starts_with?(token, "gcr.io/"),
             "external gcr.io ref in argv: #{inspect(token)}"

      refute String.starts_with?(token, "registry.example.com"),
             "external registry.example.com ref in argv: #{inspect(token)}"

      refute String.contains?(token, "://"),
             "scheme-bearing provisioning ref in argv: #{inspect(token)}"

      # Local sink with wrong port is also provisioning, not an admitted alias.
      if String.starts_with?(token, "127.0.0.1:") do
        assert token == @image or token == @init_image,
               "non-admitted loopback ref in argv: #{inspect(token)}"
      end
    end
  end

  defp refute_forbidden_tokens(plan) do
    all_argv =
      plan.argv
      |> Map.values()
      |> List.flatten()

    refute_external_provisioning_refs(all_argv)

    joined = Enum.join(all_argv, " ")

    # Exact argv tokens (short flags like -p must not substring-match --platform).
    # `--all` is allowed only on the closed verify_absent list command.
    forbidden_exact = [
      "-p",
      "-a",
      "--rm",
      "--remove",
      "--publish",
      "--ssh",
      "--env-file",
      "--privileged",
      "--cap-add"
    ]

    for token <- forbidden_exact do
      refute token in all_argv,
             "forbidden token #{inspect(token)} present in argv: #{joined}"
    end

    non_list_argv =
      plan.argv
      |> Map.drop([:verify_absent])
      |> Map.values()
      |> List.flatten()

    refute "--all" in non_list_argv,
           "--all is only permitted on verify_absent list argv: #{joined}"

    # Composite / substring forms that are never exact tokens in a well-formed plan.
    forbidden_substrings = [
      "--network=bridge",
      "--network=host",
      "network host",
      "network bridge"
    ]

    for token <- forbidden_substrings do
      refute String.contains?(joined, token),
             "forbidden token #{inspect(token)} present in argv: #{joined}"
    end

    # Network must be exactly none on create.
    create = plan.argv.create
    net_idx = Enum.find_index(create, &(&1 == "--network"))
    assert is_integer(net_idx)
    assert Enum.at(create, net_idx + 1) == "none"
    assert "--no-dns" in create

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
      "MIX_HOME=",
      "MIX_ARCHIVES=",
      "ELIXIR_MAKE_CACHE_DIR=",
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
