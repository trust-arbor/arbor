# Compile-env probe (read-only template)

Probe-only fixture; not a production release.

This directory is documentation/source only. The recompilation test
materializes a per-test temp project and never rewrites these files.
Relative path deps here are illustrative. The running test injects an
absolute `:arbor_kernel` path dep.
