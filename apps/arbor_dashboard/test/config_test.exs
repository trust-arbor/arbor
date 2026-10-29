defmodule Arbor.Dashboard.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Dashboard.Config

  @moduletag :fast

  setup do
    keys = [:local_voice_controls, :voice_api, :multimedia_api]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_dashboard, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:arbor_dashboard, key, value)
          :error -> Application.delete_env(:arbor_dashboard, key)
        end
      end
    end)

    :ok
  end

  test "voice controls require both the host opt-in and available libraries" do
    Application.put_env(:arbor_dashboard, :voice_api, __MODULE__)
    Application.put_env(:arbor_dashboard, :multimedia_api, __MODULE__)
    Application.put_env(:arbor_dashboard, :local_voice_controls, false)
    refute Config.local_voice_controls?()

    Application.put_env(:arbor_dashboard, :local_voice_controls, true)
    assert Config.local_voice_controls?()

    Application.put_env(:arbor_dashboard, :voice_api, Arbor.OptionalVoiceNotInstalled)
    refute Config.local_voice_controls?()

    Application.put_env(:arbor_dashboard, :voice_api, __MODULE__)
    Application.put_env(:arbor_dashboard, :multimedia_api, Arbor.OptionalMultimediaNotInstalled)
    refute Config.local_voice_controls?()
  end
end
