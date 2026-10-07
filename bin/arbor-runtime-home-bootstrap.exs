# Distribution starts before Elixir evaluates user code, so the launcher gives
# OTP a private HOME containing only Arbor's `.erlang.cookie`. Restore the real
# operator HOME before Mix evaluates runtime configuration or starts apps.
operator_home = System.fetch_env!("ARBOR_RUNTIME_ORIGINAL_HOME")
System.put_env("HOME", operator_home)
System.delete_env("ARBOR_RUNTIME_ORIGINAL_HOME")

# The running daemon authenticates from the cookie already loaded by OTP. It
# does not need to retain a second copy in its environment.
System.delete_env("ARBOR_COOKIE")
