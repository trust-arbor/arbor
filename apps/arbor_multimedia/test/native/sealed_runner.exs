# Explicit fresh-VM harness; never execute with a live Arbor node.
# Remove native code paths BEFORE loading any plugin production modules.
plugin_ebin = :code.lib_dir(:membrane_portaudio_plugin, :ebin)
true = :code.del_path(plugin_ebin)

for module <- [
      Membrane.PortAudio.Source.Native,
      Membrane.PortAudio.Source.Native.Nif,
      Membrane.PortAudio.Sink.Native,
      Membrane.PortAudio.Sink.Native.Nif,
      Membrane.PortAudio.OSXPermissions,
      Membrane.PortAudio.OSXPermissions.Nif,
      Membrane.PortAudio.Devices,
      Membrane.PortAudio.Devices.Nif
    ] do
  :code.purge(module)
  :code.delete(module)
  false = :code.is_loaded(module)
end

Code.compiler_options(ignore_module_conflict: true)

defmodule ArborNativeFake do
  def configure(observer),
    do:
      :persistent_term.put(__MODULE__, %{
        observer: observer,
        hold: false,
        close: :ok,
        completion: true,
        finish_frames: nil,
        permission: :authorized
      })

  def set(key, value),
    do: :persistent_term.put(__MODULE__, Map.put(:persistent_term.get(__MODULE__), key, value))

  def get(key), do: Map.fetch!(:persistent_term.get(__MODULE__), key)
  def event(event), do: send(get(:observer), {:effect, event})

  def create(kind, owner, rate, frames, token) do
    resource = make_ref()

    Process.put(resource, %{
      kind: kind,
      owner: owner,
      rate: rate,
      frames: frames,
      token: token,
      bytes: 0
    })

    event({:create, kind, owner, resource})

    if get(:hold) do
      event({:held, self()})
      receive do: (:release_native -> :ok)
    end

    if kind == :source do
      {:ok, resource, 1, rate}
    else
      send(owner, {:portaudio_correlated_demand, token, frames * 2})
      {:ok, {0, resource}}
    end
  end

  def start(resource) do
    r = Process.get(resource)
    event({:start, r.kind, resource})

    if get(:completion) do
      if r.kind == :source do
        send(
          r.owner,
          {:portaudio_correlated_payload, r.token, :binary.copy(<<12, 34>>, r.frames)}
        )

        send(r.owner, {:portaudio_correlated_capture_finished, r.token, :complete, r.frames})
      else
        send(r.owner, {:portaudio_correlated_playback_finished, r.token, :complete, r.frames})
      end
    end

    :ok
  end

  def write(payload, resource) do
    r = Process.get(resource)
    bytes = r.bytes + byte_size(payload)
    Process.put(resource, %{r | bytes: bytes})
    event({:write, payload, resource})
    if bytes == r.frames * 2, do: :ready, else: :ok
  end

  def finish(resource) do
    r = Process.get(resource)
    event({:finish, resource, r.owner, r.token})

    case get(:finish_frames) do
      nil -> :ok
      frames -> {:ok, frames}
    end
  end

  def destroy(resource) do
    event({:destroy, resource})

    case get(:close) do
      [result | rest] ->
        set(:close, if(rest == [], do: result, else: rest))
        result

      result ->
        result
    end
  end
end

defmodule Membrane.PortAudio.Source.Native do
  def __fake_device_backend__, do: true

  def create_correlated(owner, _, _, _, _, _, rate, frames, token),
    do: ArborNativeFake.create(:source, owner, rate, frames, token)

  def start(resource), do: ArborNativeFake.start(resource)
  def finish(resource), do: ArborNativeFake.finish(resource)
  def destroy(resource), do: ArborNativeFake.destroy(resource)
  def reclaim, do: :empty
end

defmodule Membrane.PortAudio.Sink.Native do
  def __fake_device_backend__, do: true

  # Exact exported native ABI: shortening this fake would stop exercising the real element call.
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def create_correlated(owner, _, _, rate, _, _, _, _, _, frames, token),
    do: ArborNativeFake.create(:sink, owner, rate, frames, token)

  def start(resource), do: ArborNativeFake.start(resource)
  def write_data(payload, resource), do: ArborNativeFake.write(payload, resource)
  def destroy(resource), do: ArborNativeFake.destroy(resource)
  def reclaim, do: :empty
end

defmodule Membrane.PortAudio.OSXPermissions do
  def __fake_device_backend__, do: true

  def authorization_status do
    ArborNativeFake.event(:permission_status)
    ArborNativeFake.get(:permission)
  end

  def request_mic do
    ArborNativeFake.event(:permission_request)
    :ok
  end
end

defmodule Membrane.PortAudio.Devices do
  def __fake_device_backend__, do: true

  def enumerate_bounded do
    ArborNativeFake.event(:enumerate)

    {:ok,
     [
       %{
         id: 1,
         name: "Fake device",
         max_input_channels: 1,
         max_output_channels: 1,
         default_sample_rate: 16_000,
         default_device: :ignored
       }
     ]}
  end

  def close(_), do: :ok
  def reclaim, do: :empty
end

for module <- [
      Membrane.PortAudio.Source.Native,
      Membrane.PortAudio.Sink.Native,
      Membrane.PortAudio.OSXPermissions,
      Membrane.PortAudio.Devices
    ],
    do: true = module.__fake_device_backend__()

false = plugin_ebin in :code.get_path()
plugin_root = System.fetch_env!("ARBOR_TEST_PORTAUDIO_SOURCE")
previous_env = Mix.env()
Mix.env(:prod)

for file <- ["sync_executor", "source", "sink"] do
  # Operator-selected reviewed checkout, fixed source filenames, and a sealed fresh test VM.
  # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
  Code.compile_file(Path.join([plugin_root, "lib/membrane_portaudio_plugin", file <> ".ex"]))
end

Mix.env(previous_env)
# Production Arbor modules must be compiled normally before entering this sealed VM.
# This harness never writes fake BEAMs or replaces dependency build artifacts.
{:module, Arbor.Multimedia} = Code.ensure_loaded(Arbor.Multimedia)
true = function_exported?(Arbor.Multimedia, :device_status, 0)
false = inspect(Arbor.Multimedia.Redacted.new("SEALED_PCM_SENTINEL")) =~ "SEALED_PCM_SENTINEL"
ExUnit.start(assert_receive_timeout: 2_000)
Code.require_file("native_driver_checks.exs", __DIR__)
