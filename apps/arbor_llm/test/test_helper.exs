# `req` decides at COMPILE TIME whether its `plug:` transport option works
# (`if Code.ensure_loaded?(Plug.Test)` in Req.Steps and Req.Test). If req is
# compiled before plug exists in the build, that support is baked out
# permanently: `Req.Steps.run_plug/1` then raises "missing plug dependency" at
# request time, which surfaces as a confusing assertion failure deep inside a
# test ("expected 1 request, got 0") rather than as the build problem it is.
#
# Both branches define run_plug/1, so this probes the real path: drive one
# request through a plug that never touches the network.
stale_req_build? =
  try do
    Req.get!(url: "http://arbor.invalid/", plug: fn conn -> conn end, retry: false)
    false
  rescue
    e in RuntimeError -> e.message == "missing plug dependency"
    _ -> false
  catch
    _, _ -> false
  end

if stale_req_build? do
  raise """
  Stale `req` build: req was compiled before `plug`, so it has no `plug:`
  transport support. Every Req.Test stub will raise "missing plug dependency",
  and tests asserting that a request was made fail with misleading counts.

  Fix (no code change needed):

      MIX_ENV=test mix deps.compile req --force
  """
end

ExUnit.start()
