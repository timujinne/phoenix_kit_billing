defmodule PhoenixKitBilling.Integration.InvoiceSendLockTest do
  @moduledoc """
  `send_invoice/2` and `create_checkout_session/3` decide and write on the
  locked invoice row, not on the struct the caller read earlier: a void that
  committed since must stay void, and its trail must survive.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing

  setup do
    user = fixture_user()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, user: user, draft: invoice}
  end

  defp send_opts, do: [to_email: "customer@example.com", send_email: false]

  describe "send_invoice/2" do
    test "a stale draft struct cannot undo a void", %{draft: draft} do
      {:ok, _voided} = Billing.void_invoice(Billing.get_invoice!(draft.uuid), "Duplicate")

      assert {:error, :invoice_not_sendable} = Billing.send_invoice(draft, send_opts())

      stored = Billing.get_invoice!(draft.uuid)
      assert stored.status == "void"
      assert stored.voided_at
      assert stored.metadata["void"]["reason"] == "Duplicate"
      refute Map.has_key?(stored.metadata, "send_history")
    end

    test "a stale sent struct cannot resend a void invoice", %{draft: draft} do
      {:ok, sent, _} = Billing.send_invoice(draft, send_opts())
      {:ok, _voided} = Billing.void_invoice(Billing.get_invoice!(sent.uuid), "Duplicate")

      assert {:error, :invoice_not_sendable} = Billing.send_invoice(sent, send_opts())

      stored = Billing.get_invoice!(sent.uuid)
      assert stored.status == "void"
      assert stored.metadata["void"]["reason"] == "Duplicate"
      assert length(stored.metadata["send_history"]) == 1
    end

    test "a refused send emails nobody", %{draft: draft} do
      {:ok, _} = Billing.void_invoice(Billing.get_invoice!(draft.uuid))

      # With the email on, an accepted send would at least return a third element.
      assert {:error, :invoice_not_sendable} =
               Billing.send_invoice(draft, to_email: "customer@example.com")
    end

    test "the history is merged into the stored metadata, not the caller's", %{draft: draft} do
      {:ok, sent, _} = Billing.send_invoice(draft, send_opts())
      stale = Billing.get_invoice!(sent.uuid)

      stale_copy = %{stale | metadata: %{}}

      {:ok, _} =
        sent
        |> Ecto.Changeset.change(metadata: Map.put(sent.metadata, "ref", "42"))
        |> Repo.update()

      assert {:ok, resent, _} = Billing.send_invoice(stale_copy, send_opts())
      assert resent.metadata["ref"] == "42"
      assert length(resent.metadata["send_history"]) == 2
    end

    test "keeps the order and user loaded on the returned invoice", %{draft: draft} do
      assert {:ok, sent, _} = Billing.send_invoice(draft, send_opts())
      refute match?(%Ecto.Association.NotLoaded{}, sent.user)
      refute match?(%Ecto.Association.NotLoaded{}, sent.order)
    end

    test "an invoice deleted meanwhile is reported, not raised", %{draft: draft} do
      Repo.delete!(draft)
      assert {:error, :invoice_not_found} = Billing.send_invoice(draft, send_opts())
    end
  end

  describe "create_checkout_session/3" do
    test "refuses an invoice that is void on the stored row, before any provider call", %{
      draft: draft
    } do
      {:ok, sent, _} = Billing.send_invoice(draft, send_opts())
      {:ok, _} = Billing.void_invoice(Billing.get_invoice!(sent.uuid))

      assert {:error, :invoice_not_payable} =
               Billing.create_checkout_session(sent, :stripe,
                 success_url: "https://example.com/ok"
               )
    end
  end

  describe "record_checkout_session/3" do
    test "merges the session into the stored metadata", %{draft: draft} do
      {:ok, sent, _} = Billing.send_invoice(draft, send_opts())

      {:ok, _} =
        sent
        |> Ecto.Changeset.change(metadata: Map.put(sent.metadata, "ref", "42"))
        |> Repo.update()

      stale = %{sent | metadata: %{}}

      assert :ok =
               Billing.record_checkout_session(stale, :stripe, %{
                 id: "cs_1",
                 url: "https://pay.example/1"
               })

      stored = Billing.get_invoice!(sent.uuid)
      assert stored.metadata["ref"] == "42"
      assert stored.metadata["checkout"]["provider_session_id"] == "cs_1"
      assert length(stored.metadata["send_history"]) == 1
    end

    test "writes nothing on an invoice that was voided meanwhile", %{draft: draft} do
      {:ok, sent, _} = Billing.send_invoice(draft, send_opts())
      {:ok, _} = Billing.void_invoice(Billing.get_invoice!(sent.uuid), "Duplicate")

      assert {:error, :invoice_not_payable} =
               Billing.record_checkout_session(sent, :stripe, %{
                 id: "cs_1",
                 url: "https://pay.example/1"
               })

      stored = Billing.get_invoice!(sent.uuid)
      refute Map.has_key?(stored.metadata, "checkout")
      assert stored.metadata["void"]["reason"] == "Duplicate"
    end
  end
end
