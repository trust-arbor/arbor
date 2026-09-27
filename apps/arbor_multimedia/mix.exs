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
      test_ignore_filters: [~r"^test/support/"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {Arbor.Multimedia.Application, []}]

  defp deps do
    [
      {:membrane_core,
       git: "http://10.42.42.6:3000/trust-arbor/membrane_core.git",
       ref: "bc01d4f7d08522a5e5028078a082a311161b7b9c",
       override: true},
      {:membrane_portaudio_plugin,
       git: "http://10.42.42.6:3000/trust-arbor/membrane_portaudio_plugin.git",
       ref: "3ecfad95d64b0edde79219c37934ac660083d9a6"},
      {:membrane_raw_audio_format, "~> 0.12.3"}
    ]
  end
end
