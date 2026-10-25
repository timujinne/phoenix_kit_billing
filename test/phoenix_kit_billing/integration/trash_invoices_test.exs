defmodule PhoenixKitBilling.Integration.TrashInvoicesTest do
  @moduledoc """
  Moving a draft invoice to the trash and back. Only a draft that was never
  sent can go there - an issued invoice is voided - and a trashed invoice
  refuses everything that would send, pay, edit or void it. Decided on the
  locked row; refusals are values.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Events, Invoice}

  setup do
    user = fixture_user()
    {:ok, user: user, actor: fixture_user().uuid}
  end

  defp draft(user, attrs \\ %{}) do
    {:ok, invoice} =
      Billing.create_invoice(
        user.uuid,
        Map.merge(%{total: Decimal.new("100.00"), currency: "EUR"}, attrs)
      )

    invoice
  end

  # Straight to `status`, whatever the workflow says about the way there.
  defp with_status(invoice, status) do
    invoice |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end

  defp order(user) do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    order
  end

  defp stored(invoice), do: Billing.get_invoice!(invoice.uuid)

  defp trashed(user, actor) do
    {:ok, trashed} = Billing.trash_invoice(draft(user), actor_uuid: actor)
    trashed
  end

  describe "trash_invoice/2" do
    test "trashes a draft that was never sent: when, by whom, and nothing else changes", %{
      user: user,
      actor: actor
    } do
      invoice = draft(user)

      assert {:ok, trashed} = Billing.trash_invoice(invoice, actor_uuid: actor)

      assert %DateTime{} = trashed.trashed_at
      assert trashed.trashed_by_uuid == actor

      row = stored(invoice)
      assert Invoice.trashed?(row)
      refute Invoice.open?(row)
      assert row.status == "draft"
      assert row.invoice_number == invoice.invoice_number
      assert row.metadata == invoice.metadata
    end

    test "the actor is optional", %{user: user} do
      assert {:ok, trashed} = Billing.trash_invoice(draft(user))
      assert trashed.trashed_by_uuid == nil
    end

    test "an issued invoice is never trashed", %{user: user} do
      for status <- ~w(sent overdue paid void) do
        invoice = draft(user) |> with_status(status)

        assert {:error, :invoice_not_trashable} = Billing.trash_invoice(invoice), status
        refute Invoice.trashed?(stored(invoice)), status
      end
    end

    test "a draft that has been sent is refused", %{user: user} do
      sent_draft =
        draft(user)
        |> Ecto.Changeset.change(sent_at: DateTime.truncate(DateTime.utc_now(), :second))
        |> Repo.update!()

      assert {:error, :invoice_not_trashable} = Billing.trash_invoice(sent_draft)
    end

    test "one that is in the trash already is refused", %{user: user, actor: actor} do
      trashed = trashed(user, actor)

      assert {:error, :already_trashed} = Billing.trash_invoice(trashed)
      assert {:error, :already_trashed} = Billing.trash_invoice(%{trashed | trashed_at: nil})
    end

    test "one that has gone is not found", %{user: user} do
      invoice = draft(user)
      Repo.delete!(invoice)

      assert {:error, :invoice_not_found} = Billing.trash_invoice(invoice)
    end

    test "decides on the locked row: an invoice sent since the struct was read is not trashed",
         %{user: user} do
      stale = draft(user)
      {:ok, _, _} = Billing.send_invoice(stale, to_email: "c@example.com", send_email: false)

      assert {:error, :invoice_not_trashable} = Billing.trash_invoice(stale)
      refute Invoice.trashed?(stored(stale))
    end

    test "decides on the locked row: an invoice voided since the struct was read is not trashed",
         %{user: user} do
      stale = draft(user)
      {:ok, _} = Billing.void_invoice(stale)

      assert {:error, :invoice_not_trashable} = Billing.trash_invoice(stale)
    end

    test "refusals leave a caller's transaction usable", %{user: user} do
      sent = draft(user) |> with_status("sent")
      already = trashed(user, nil)
      never_trashed = draft(user)

      assert {:ok, {refusals, other_uuid}} =
               Repo.transaction(fn ->
                 refusals = [
                   Billing.trash_invoice(sent),
                   Billing.trash_invoice(already),
                   Billing.restore_invoice(never_trashed)
                 ]

                 {refusals, draft(user).uuid}
               end)

      assert refusals == [
               {:error, :invoice_not_trashable},
               {:error, :already_trashed},
               {:error, :not_trashed}
             ]

      assert Billing.get_invoice(other_uuid)
    end
  end

  describe "restore_invoice/2" do
    test "clears when and by whom, and the invoice is a plain draft again", %{
      user: user,
      actor: actor
    } do
      trashed = trashed(user, actor)

      assert {:ok, restored} = Billing.restore_invoice(trashed)
      assert restored.trashed_at == nil
      assert restored.trashed_by_uuid == nil

      row = stored(trashed)
      refute Invoice.trashed?(row)
      assert Invoice.open?(row)
      assert row.status == "draft"
      assert {:ok, _} = Billing.update_invoice(row, %{notes: "back"})
    end

    test "one that is not in the trash is refused", %{user: user} do
      assert {:error, :not_trashed} = Billing.restore_invoice(draft(user))
    end

    test "decides on the stored row", %{user: user} do
      trashed = trashed(user, nil)
      {:ok, _} = Billing.restore_invoice(trashed)

      assert {:error, :not_trashed} = Billing.restore_invoice(trashed)
    end

    test "one that has gone is not found", %{user: user} do
      trashed = trashed(user, nil)
      Repo.delete!(trashed)

      assert {:error, :invoice_not_found} = Billing.restore_invoice(trashed)
    end

    test "is refused while its order is in the trash - an order in the trash has no open invoice",
         %{user: user} do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, trashed_invoice} = Billing.trash_invoice(invoice)
      {:ok, _} = Billing.trash_order(order)

      assert {:error, :order_trashed} = Billing.restore_invoice(trashed_invoice)
      assert Invoice.trashed?(stored(invoice))

      {:ok, _} = Billing.restore_order(order)
      assert {:ok, _} = Billing.restore_invoice(trashed_invoice)
    end
  end

  describe "a trashed invoice refuses to change" do
    setup %{user: user, actor: actor} do
      trashed = trashed(user, actor)
      stale = %{trashed | trashed_at: nil, trashed_by_uuid: nil}
      {:ok, trashed: trashed, stale: stale}
    end

    test "update_invoice/2", %{trashed: trashed, stale: stale} do
      for invoice <- [trashed, stale] do
        assert {:error, :invoice_trashed} = Billing.update_invoice(invoice, %{notes: "x"})
      end

      assert stored(trashed).notes == nil
    end

    test "send_invoice/2 - nobody is emailed", %{trashed: trashed, stale: stale} do
      for invoice <- [trashed, stale] do
        assert {:error, :invoice_trashed} =
                 Billing.send_invoice(invoice, to_email: "c@example.com")
      end

      row = stored(trashed)
      assert row.status == "draft"
      assert row.sent_at == nil
      assert row.metadata["send_history"] == nil
    end

    test "send_invoice_email/2", %{trashed: trashed} do
      assert {:error, :invoice_trashed} =
               Billing.send_invoice_email(trashed, to_email: "c@example.com")
    end

    test "mark_invoice_paid/2", %{trashed: trashed, stale: stale} do
      assert {:error, :invoice_trashed} = Billing.mark_invoice_paid(trashed)

      # A struct read when the invoice was sent and payable: the stored row says no.
      assert {:error, :invoice_trashed} = Billing.mark_invoice_paid(%{stale | status: "sent"})

      assert stored(trashed).status == "draft"
    end

    test "record_payment/3 and record_refund/3", %{trashed: trashed, stale: stale} do
      payable = %{stale | status: "sent"}
      paid = %{stale | status: "paid", paid_amount: Decimal.new("100.00")}

      assert {:error, :invoice_trashed} = Billing.record_payment(trashed, %{amount: "1.00"}, nil)
      assert {:error, :invoice_trashed} = Billing.record_payment(payable, %{amount: "1.00"}, nil)
      assert {:error, :invoice_trashed} = Billing.record_refund(trashed, %{amount: "1.00"}, nil)
      assert {:error, :invoice_trashed} = Billing.record_refund(paid, %{amount: "1.00"}, nil)

      assert Billing.list_invoice_transactions(trashed.uuid) == []
    end

    test "void_invoice/3", %{trashed: trashed, stale: stale} do
      for invoice <- [trashed, stale] do
        assert {:error, :invoice_trashed} = Billing.void_invoice(invoice, "no")
      end

      row = stored(trashed)
      assert row.status == "draft"
      assert row.voided_at == nil
    end

    test "the refusals leave a caller's transaction usable", %{user: user, trashed: trashed} do
      assert {:ok, {refusals, _}} =
               Repo.transaction(fn ->
                 refusals = [
                   Billing.update_invoice(trashed, %{notes: "x"}),
                   Billing.send_invoice(trashed, to_email: "c@example.com"),
                   Billing.void_invoice(trashed),
                   Billing.record_payment(trashed, %{amount: "1.00"}, nil)
                 ]

                 {refusals, draft(user)}
               end)

      assert refusals == List.duplicate({:error, :invoice_trashed}, 4)
    end
  end

  describe "billing's own fields cannot be forged" do
    test "create_invoice/2 and update_invoice/2 ignore them", %{user: user, actor: actor} do
      forged = %{trashed_at: ~U[2026-01-01 00:00:00Z], trashed_by_uuid: actor}

      invoice = draft(user, forged)
      refute Invoice.trashed?(stored(invoice))

      assert {:ok, updated} = Billing.update_invoice(invoice, forged)
      refute Invoice.trashed?(updated)
      refute Invoice.trashed?(stored(invoice))
    end

    test "update_invoice/2 cannot lift a trashed invoice out of the trash", %{user: user} do
      trashed = trashed(user, nil)

      assert {:error, :invoice_trashed} =
               Billing.update_invoice(trashed, %{trashed_at: nil, trashed_by_uuid: nil})

      assert Invoice.trashed?(stored(trashed))
    end
  end

  describe "events" do
    setup %{user: user} do
      Events.subscribe_invoices()
      Events.subscribe_user_invoices(user.uuid)
      :ok
    end

    test "trash_invoice/2 announces :invoice_trashed, and only that", %{user: user} do
      invoice = draft(user)
      flush_events()

      {:ok, trashed} = Billing.trash_invoice(invoice)

      uuid = trashed.uuid
      assert_receive {:invoice_trashed, %Invoice{uuid: ^uuid, trashed_at: %DateTime{}}}
      assert_receive {:invoice_trashed, %Invoice{uuid: ^uuid}}
      refute_received {:invoice_voided, _}
      refute_received {:invoice_trashed, _}
    end

    test "restore_invoice/2 announces :invoice_restored", %{user: user} do
      {:ok, trashed} = Billing.trash_invoice(draft(user))
      flush_events()

      {:ok, restored} = Billing.restore_invoice(trashed)

      uuid = restored.uuid
      assert_receive {:invoice_restored, %Invoice{uuid: ^uuid, trashed_at: nil}}
    end

    test "a refusal announces nothing", %{user: user} do
      sent = draft(user) |> with_status("sent")
      flush_events()

      assert {:error, :invoice_not_trashable} = Billing.trash_invoice(sent)
      assert {:error, :not_trashed} = Billing.restore_invoice(sent)

      refute_received {:invoice_trashed, _}
      refute_received {:invoice_restored, _}
    end
  end

  defp flush_events do
    receive do
      _ -> flush_events()
    after
      0 -> :ok
    end
  end
end
