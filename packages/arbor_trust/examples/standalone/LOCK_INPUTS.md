# Public lock inputs

`mix.lock` is a source-only projection of the reviewed actual repository lock:
Boundary, Finch, HPAX, Jason, MIME, Mint, NimbleOptions, NimblePool, PlugCrypto,
Req, Telemetry, TypedStruct and PhoenixPubSub. These are the production/build
closure; StreamData is owning-test-only and is omitted from this consumer.
There are no first-party private tarball, Git or local-lock entries.

The runner must supply the seven first-party archive roots and private source
checkouts of these exact public locked third-party dependencies. It must build
from source without Main `_build`, precompiled app caches, or copied BEAMs.
Each attempt must check locked/public dependency metadata and retain its actual
resolution/build receipts. A resolution or build failure holds the attempt;
versions must not be silently edited to obtain acceptance.
