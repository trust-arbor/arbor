defmodule Arbor.Voice.NativeRuntimeConfigTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @runtime Path.expand("../../../../../config/runtime.exs", __DIR__)
  # Reading the full runtime file must not activate another host opt-in. Clear
  # literal inputs; dynamic companion fields stay unreachable with flags unset.
  @keys Regex.scan(~r/System\.(?:get_env|fetch_env!)\("([A-Z0-9_]+)"/, File.read!(@runtime))
        |> Enum.map(fn [_, key] -> key end)
        |> Enum.uniq()

  setup do
    assert "ARBOR_AUDIO_DRIVER" in @keys
    assert "ARBOR_HOME" in @keys
    previous = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)

    root =
      Path.join(System.tmp_dir!(), "voice-native-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    System.put_env("ARBOR_HOME", root)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "native non-test opt-in explicitly binds the voice ledger to the canonical durable Repo",
       %{root: root} do
    System.put_env("ARBOR_AUDIO_DRIVER", "native")
    config = read_runtime(root, :dev)
    assert config[:arbor_voice][:budget_backend] == Arbor.Persistence.QueryableStore.Postgres
    assert config[:arbor_voice][:budget_backend_opts] == [repo: Arbor.Persistence.Repo]
    assert config[:arbor_multimedia][:driver] == Arbor.Multimedia.Driver.Native
  end

  test "ambient native selection cannot enable the production ledger in test", %{root: root} do
    System.put_env("ARBOR_AUDIO_DRIVER", "native")
    config = read_runtime(root, :test)
    assert config[:arbor_voice][:budget_backend] == nil
    assert config[:arbor_voice][:budget_backend_opts] == nil
    assert config[:arbor_multimedia][:driver] == nil
  end

  test "unavailable or absent device opt-in does not configure the voice ledger", %{root: root} do
    for driver <- [nil, "unavailable"] do
      if driver,
        do: System.put_env("ARBOR_AUDIO_DRIVER", driver),
        else: System.delete_env("ARBOR_AUDIO_DRIVER")

      config = read_runtime(root, :dev)
      assert config[:arbor_voice][:budget_backend] == nil
    end
  end

  defp read_runtime(root, env),
    do: File.cd!(root, fn -> Config.Reader.read!(@runtime, env: env, target: :host) end)
end
