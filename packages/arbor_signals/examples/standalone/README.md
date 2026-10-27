# Standalone consumer

This independent Mix project exercises the package through its public facade.
It checks delivery, retained history, restricted subscriptions with absent and
configured providers, stop/restart, and loaded, started and compiled application
closure. It must not load or compile another Arbor application.

From the repository root, run the external-copy qualification:

```sh
python3 packages/arbor_signals/scripts/qualify_standalone.py \
  --work-dir /absolute/fresh/private/qualification-directory \
  --mix "$PWD/bin/mix"
```

The script copies only production package source and this consumer to the chosen
location, then performs a fresh dependency resolution and build. It also assembles
a production release and runs the same canary with Mix absent. The directory and
all logs are retained. Add `--offline` to use already cached public Hex inputs.
