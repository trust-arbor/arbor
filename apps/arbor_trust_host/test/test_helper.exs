{:ok, _} = Application.ensure_all_started(:arbor_kernel_runtime)
:ok = Arbor.Signals.ensure_supervised_local_runtime!()
Arbor.Security.TestBootstrap.start!()
ExUnit.start(exclude: [:llm, :llm_local])
