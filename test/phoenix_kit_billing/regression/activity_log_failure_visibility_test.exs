defmodule PhoenixKitBilling.Regression.ActivityLogFailureVisibilityTest do
  @moduledoc """
  A logging failure must come back as something distinguishable from
  success. `Activity.log/2` delegates to `PhoenixKit.Activity.log/3`,
  which turns a raise or an exit into a logged, returned `{:error, _}` —
  this pins that billing's call still gets that result and a log line,
  rather than a bare `:ok` or a crash.

  `DBConnection.OwnershipError` is reached for real, not mocked:
  `async: true` puts the test repo in non-shared ownership mode (see
  `data_case.ex`), and the logging call runs inside a bare `spawn/1`
  process — not `Task.async/1`, which sets `$callers` and gets
  auto-allowed onto the spawning process's sandbox connection, defeating
  the point of this test.
  """

  use PhoenixKitBilling.DataCase, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitBilling.Activity

  test "a DB ownership failure during logging is logged and returned as a distinguishable error" do
    test_pid = self()

    log =
      capture_log(fn ->
        {pid, ref} =
          spawn_monitor(fn ->
            result =
              Activity.log("billing.order_created",
                actor_uuid: "01a01234-1234-7234-8234-123412341234",
                resource_type: "order",
                resource_uuid: "01a01234-1234-7234-8234-123412341235"
              )

            send(test_pid, {:result, result})
          end)

        # The ownership failure can take longer than a second under load.
        assert_receive {:result, result}, 5000
        assert {:error, %DBConnection.OwnershipError{}} = result
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
      end)

    assert log =~ "Activity logging"
  end
end
