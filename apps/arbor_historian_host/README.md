# Historian product host

Passive composition for the canonical active `:arbor_historian` package. This
project starts no callback, registered process or authority tree. KernelRuntime
and the existing product authority/storage hosts precede canonical Historian.
Authorizer and AuthoritySource delegate to the public Security facade inline;
AuthoritySource must preserve the real puller's PID. Observation and DurableSink
implement the consumer-owned Signals boundary. The historical SecurityEventLog
module and all product SQL/Capabilities/Signals integration tests live here.
TestAuditRepo/TestAuditRuntime compile only in this host's test support; SQL
migrations come from the public Persistence SQL package. Core owns no SQL fixture.
