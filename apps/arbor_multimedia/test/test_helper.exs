ExUnit.start()
# All tests choose an explicit fake before application start. No passthrough mocks.
Code.require_file("support/fake_driver.ex", __DIR__)
Application.put_env(:arbor_multimedia, :driver, Arbor.Multimedia.FakeDriver)
