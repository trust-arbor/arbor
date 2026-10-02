Code.require_file(Path.expand("../../build_support/mix_project_paths.exs", __DIR__))

defmodule Arbor.Multimedia.MixProject do
  use Mix.Project

  def project do
    paths =
      Arbor.MixProjectPaths.project_paths(build_path: "../../_build", deps_path: "../../deps")

    [
      app: :arbor_multimedia,
      version: "0.1.0",
      build_path: paths[:build_path],
      config_path: "../../config/config.exs",
      deps_path: paths[:deps_path],
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r"^test/support/", ~r"^test/native/"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {Arbor.Multimedia.Application, []}]

  defp deps do
    [
      {:membrane_core,
       git: "http://10.42.42.6:3000/trust-arbor/membrane_core.git",
       ref: "c2e9c7aff031dd600d2318b72193a4825b0da95f",
       override: true},
      {:membrane_portaudio_plugin,
       git: "http://10.42.42.6:3000/trust-arbor/membrane_portaudio_plugin.git",
       ref: "c4e85f4d9ec4e080a7713f5f9878c67a658997c1"},
      {:membrane_raw_audio_format, "~> 0.12.3"}
    ]
  end
end
