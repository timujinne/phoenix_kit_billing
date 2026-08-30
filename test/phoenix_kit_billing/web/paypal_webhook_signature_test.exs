defmodule PhoenixKitBilling.Web.PaypalWebhookSignatureTest do
  @moduledoc """
  Destructive tests for the PayPal webhook fail-closed fix (B008).

  The bug: `PhoenixKitBilling.Providers.PayPal.verify_webhook_via_api/3`
  has two clauses — one guarded `when is_map(headers)` that calls PayPal's
  verify-webhook-signature API, and a catch-all for anything else. The
  webhook controller's `get_signature/2` always extracts the signature
  header as a plain string (same as Stripe/Razorpay), so the guarded
  clause never matches and every real invocation falls into the catch-all.
  That catch-all used to return `:ok` unconditionally — fail-open: any
  request, forged or not, was accepted.

  The fix flips that `:ok` to `{:error, :invalid_signature}` — fail-closed.

  These tests drive the real `WebhookController.paypal/2` action (not a
  reimplementation of its logic) and assert on the HTTP response, not
  just a log line, per the card's requirement that rejection be visible
  in the response.

  PayPal's OAuth token endpoint is stubbed via `Req.Test` (wired through
  the `:paypal_req_options` application env merged into
  `PayPal.get_access_token/0` — a test-only seam that changes nothing in
  production, where that env key is never set) so this suite never makes
  a real network call to PayPal.

  Scope note: a "valid signature is accepted" case is intentionally NOT
  included here. Because the controller always passes the signature as a
  string, the guarded (real, API-calling) clause is unreachable from any
  production call site — after this fix, every PayPal webhook is
  rejected regardless of whether the signature was genuinely valid. Full
  verification (collecting PayPal's 5 signature headers into a map and
  fixing this dispatch) is separate, larger work explicitly deferred by
  the owner's scope decision — see the B008 report for detail.
  """

  use PhoenixKitBilling.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Web.WebhookController

  @secret "b008-test-webhook-secret"
  @raw_body ~s({"id":"WH-B008-TEST","event_type":"PAYMENT.CAPTURE.COMPLETED"})

  setup do
    Settings.update_setting("billing_paypal_client_id", "b008-test-client-id")
    Settings.update_setting("billing_paypal_client_secret", "b008-test-client-secret")
    Settings.update_setting("billing_paypal_webhook_secret", @secret)

    Application.put_env(:phoenix_kit_billing, :paypal_req_options, plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"access_token" => "b008-test-access-token"})
    end)

    on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :paypal_req_options) end)

    :ok
  end

  defp post_webhook(opts) do
    conn =
      :post
      |> conn("/webhooks/billing/paypal", "")
      |> assign(:raw_body, Keyword.get(opts, :raw_body, @raw_body))

    case Keyword.fetch(opts, :signature) do
      {:ok, sig} -> put_req_header(conn, "paypal-transmission-sig", sig)
      :error -> conn
    end
    |> WebhookController.paypal(%{})
  end

  test "a forged signature is rejected, and the rejection is visible in the HTTP response" do
    conn = post_webhook(signature: "forged-signature-an-attacker-can-set-to-anything")

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "Invalid signature"}
  end

  test "a missing signature header is rejected" do
    conn = post_webhook([])

    assert conn.status != 200
    assert %{"status" => "ok"} != Jason.decode!(conn.resp_body)
  end

  test "OAuth succeeding is not, by itself, enough to accept the request" do
    # Guards against a regression where someone "fixes" this by short-
    # circuiting on get_access_token success instead of actually checking
    # the signature — the access token stub above always succeeds, so if
    # the endpoint ever starts returning 200 here, fail-closed broke.
    conn = post_webhook(signature: "still-forged")

    refute conn.status == 200
  end
end
