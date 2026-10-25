defmodule PhoenixKitBilling.Integration.ContextTest do
  @moduledoc """
  Context CRUD tests for `PhoenixKitBilling` functions exercisable
  without external payment APIs.

  `async: true` — no global settings touched here. Currency tests use
  non-seeded codes (EUR/GBP/USD are seeded by core V31, EUR is default).
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Events

  # ── Currencies ───────────────────────────────────────────────────

  describe "currencies" do
    test "create_currency/1 inserts and upcases the code" do
      assert {:ok, c} = Billing.create_currency(%{code: "chf", name: "Swiss Franc", symbol: "Fr"})
      assert c.code == "CHF"
    end

    test "create_currency/1 returns error changeset for invalid attrs" do
      assert {:error, cs} = Billing.create_currency(%{code: "X", name: "", symbol: ""})
      assert %{code: [_ | _], name: [_ | _]} = errors_on(cs)
    end

    test "get_currency/1 by uuid and get_currency_by_code/1" do
      {:ok, c} = Billing.create_currency(%{code: "sek", name: "Krona", symbol: "kr"})
      assert Billing.get_currency(c.uuid).uuid == c.uuid
      assert Billing.get_currency_by_code("sek").uuid == c.uuid
      assert Billing.get_currency("not-a-uuid") == nil
    end

    test "update_currency/2 changes fields" do
      {:ok, c} = Billing.create_currency(%{code: "nok", name: "Krone", symbol: "kr"})
      assert {:ok, updated} = Billing.update_currency(c, %{name: "Norwegian Krone"})
      assert updated.name == "Norwegian Krone"
    end

    test "list_currencies/1 with enabled filter" do
      {:ok, _} =
        Billing.create_currency(%{code: "dkk", name: "DKK", symbol: "kr", enabled: false})

      enabled_codes = Billing.list_currencies(enabled: true) |> Enum.map(& &1.code)
      disabled_codes = Billing.list_currencies(enabled: false) |> Enum.map(& &1.code)
      assert "EUR" in enabled_codes
      assert "DKK" in disabled_codes
      refute "DKK" in enabled_codes
    end

    test "get_default_currency/1 returns the seeded EUR default" do
      assert %Currency{code: "EUR", is_default: true} = Billing.get_default_currency()
    end

    test "set_default_currency/1 moves the default flag" do
      {:ok, c} = Billing.create_currency(%{code: "pln", name: "Zloty", symbol: "zl"})
      assert {:ok, _} = Billing.set_default_currency(c)

      assert Billing.get_default_currency().code == "PLN"
      # old default (EUR) is no longer default
      assert Billing.get_currency_by_code("EUR").is_default == false
    end

    test "delete_currency/1 refuses the default" do
      default = Billing.get_default_currency()
      assert {:error, :is_default} = Billing.delete_currency(default)
    end

    test "delete_currency/1 deletes a non-default, unused currency" do
      {:ok, c} = Billing.create_currency(%{code: "huf", name: "Forint", symbol: "Ft"})
      assert {:ok, _} = Billing.delete_currency(c)
      assert Billing.get_currency(c.uuid) == nil
    end

    test "delete_currency/1 refuses a currency referenced by an order" do
      {:ok, c} = Billing.create_currency(%{code: "czk", name: "Koruna", symbol: "Kc"})

      {:ok, _order} =
        Billing.create_order(%{
          "user_uuid" => fixture_user().uuid,
          "currency" => "CZK",
          "total" => Decimal.new("10.00"),
          "billing_snapshot" => %{"email" => "g@example.com"}
        })

      assert {:error, :currency_in_use} = Billing.delete_currency(c)
    end
  end

  # ── Orders ───────────────────────────────────────────────────────

  describe "orders" do
    setup do
      {:ok, user: fixture_user()}
    end

    test "create_order/2 with a user struct", %{user: user} do
      assert {:ok, order} =
               Billing.create_order(user, %{
                 "total" => Decimal.new("99.00"),
                 "currency" => "EUR",
                 "billing_snapshot" => %{"email" => "g@example.com"}
               })

      assert order.user_uuid == user.uuid
      assert order.status == "draft"
    end

    test "create_order/2 defaults currency from settings when omitted", %{user: user} do
      assert {:ok, order} =
               Billing.create_order(user, %{
                 "total" => Decimal.new("5.00"),
                 "billing_snapshot" => %{"email" => "g@example.com"}
               })

      assert order.currency == "EUR"
    end

    test "create_order/1 with invalid attrs returns error changeset", %{user: user} do
      assert {:error, cs} =
               Billing.create_order(%{"user_uuid" => user.uuid, "total" => Decimal.new("-1")})

      assert %{total: [_ | _]} = errors_on(cs)
    end

    test "get_order/2 and get_order_by_number/1", %{user: user} do
      {:ok, order} = create_basic_order(user)
      assert Billing.get_order(order.uuid).uuid == order.uuid
      assert Billing.get_order_by_number(order.order_number).uuid == order.uuid
      assert Billing.get_order("not-a-uuid") == nil
    end

    test "update_order/2 only when editable", %{user: user} do
      {:ok, order} = create_basic_order(user)
      assert {:ok, updated} = Billing.update_order(order, %{"notes" => "hello"})
      assert updated.notes == "hello"

      {:ok, confirmed} = Billing.confirm_order(order)
      assert {:error, :order_not_editable} = Billing.update_order(confirmed, %{"notes" => "x"})
    end

    test "confirm_order/1 and mark_order_paid/2 follow the status workflow", %{user: user} do
      {:ok, order} = create_basic_order(user)
      assert {:ok, confirmed} = Billing.confirm_order(order)
      assert confirmed.status == "confirmed"

      assert {:ok, paid} = Billing.mark_order_paid(confirmed, payment_method: "bank")
      assert paid.status == "paid"
      assert paid.payment_method == "bank"

      # paid is not payable again
      assert {:error, :order_not_payable} = Billing.mark_order_paid(paid)
    end

    test "mark_order_refunded/1 broadcasts :order_refunded on the orders and user topics",
         %{user: user} do
      {:ok, order} = create_basic_order(user)
      {:ok, confirmed} = Billing.confirm_order(order)
      {:ok, paid} = Billing.mark_order_paid(confirmed)

      Events.subscribe_orders()
      Events.subscribe_user_orders(user.uuid)

      assert {:ok, refunded} = Billing.mark_order_refunded(paid)
      assert refunded.status == "refunded"

      assert_receive {:order_refunded, %{uuid: uuid, status: "refunded"}}
      assert uuid == order.uuid
      assert_receive {:order_refunded, %{uuid: ^uuid}}
    end

    test "mark_order_refunded/1 broadcasts nothing for an order that is not paid", %{user: user} do
      {:ok, order} = create_basic_order(user)
      Events.subscribe_orders()

      assert {:error, :order_not_refundable} = Billing.mark_order_refunded(order)
      refute_receive {:order_refunded, _}
    end

    test "record_refund/3 broadcasts :order_refunded once, and only for a full refund",
         %{user: user} do
      {:ok, order} = create_basic_order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)

      {:ok, invoice, :skipped} =
        Billing.send_invoice(invoice, to_email: user.email, send_email: false)

      {:ok, _payment} = Billing.record_payment(invoice, %{amount: invoice.total}, nil)
      assert Billing.get_order!(order.uuid).status == "paid"

      Events.subscribe_orders()
      paid_invoice = Billing.get_invoice!(invoice.uuid)

      {:ok, _partial} = Billing.record_refund(paid_invoice, %{amount: "1.00"}, nil)
      refute_receive {:order_refunded, _}

      remaining = Billing.get_invoice!(invoice.uuid)
      {:ok, _rest} = Billing.record_refund(remaining, %{amount: remaining.paid_amount}, nil)

      assert Billing.get_order!(order.uuid).status == "refunded"
      assert_receive {:order_refunded, %{uuid: uuid, status: "refunded"}}
      assert uuid == order.uuid
      refute_receive {:order_refunded, _}
    end

    test "cancel_order/2 records reason", %{user: user} do
      {:ok, order} = create_basic_order(user)
      assert {:ok, cancelled} = Billing.cancel_order(order, "changed mind")
      assert cancelled.status == "cancelled"
      assert cancelled.internal_notes == "changed mind"
    end

    test "delete_order/1 only deletes drafts", %{user: user} do
      {:ok, order} = create_basic_order(user)
      {:ok, confirmed} = Billing.confirm_order(order)
      assert {:error, :can_only_delete_drafts} = Billing.delete_order(confirmed)

      {:ok, draft} = create_basic_order(user)
      assert {:ok, _} = Billing.delete_order(draft)
      assert Billing.get_order(draft.uuid) == nil
    end

    test "list_orders/1 and list_user_orders/2", %{user: user} do
      {:ok, order} = create_basic_order(user)
      assert Enum.any?(Billing.list_orders(), &(&1.uuid == order.uuid))
      assert Enum.any?(Billing.list_user_orders(user.uuid), &(&1.uuid == order.uuid))
    end
  end

  # ── Invoices ─────────────────────────────────────────────────────

  describe "invoices" do
    setup do
      {:ok, user: fixture_user()}
    end

    test "create_invoice/2 generates an invoice number", %{user: user} do
      assert {:ok, invoice} =
               Billing.create_invoice(user, %{total: Decimal.new("50.00"), currency: "EUR"})

      assert invoice.user_uuid == user.uuid
      assert is_binary(invoice.invoice_number)
      assert invoice.invoice_number =~ "INV"
    end

    test "create_invoice_from_order/2 copies order data", %{user: user} do
      {:ok, order} = create_basic_order(user)
      assert {:ok, invoice} = Billing.create_invoice_from_order(order)
      assert invoice.order_uuid == order.uuid
      assert invoice.total == order.total
      assert invoice.status == "draft"
    end

    test "get_invoice/2 and get_invoice_by_number/1", %{user: user} do
      {:ok, invoice} =
        Billing.create_invoice(user, %{total: Decimal.new("10.00"), currency: "EUR"})

      assert Billing.get_invoice(invoice.uuid).uuid == invoice.uuid
      assert Billing.get_invoice_by_number(invoice.invoice_number).uuid == invoice.uuid
      assert Billing.get_invoice("not-a-uuid") == nil
    end

    test "update_invoice/2 only when editable (draft)", %{user: user} do
      {:ok, invoice} =
        Billing.create_invoice(user, %{total: Decimal.new("10.00"), currency: "EUR"})

      assert {:ok, updated} = Billing.update_invoice(invoice, %{notes: "n"})
      assert updated.notes == "n"
    end

    # Rollup panels (the projects-hub Customer billing tab) ask for the
    # most recent few. Without a query-level limit they pull a customer's
    # entire invoice history into memory and slice it there.
    test "list_user_invoices/2 honors the :limit filter", %{user: user} do
      for _ <- 1..4 do
        {:ok, _} = Billing.create_invoice(user, %{total: Decimal.new("1.00"), currency: "EUR"})
      end

      assert length(Billing.list_user_invoices(user.uuid)) == 4
      assert length(Billing.list_user_invoices(user.uuid, %{limit: 2})) == 2

      # Newest first, so the limit keeps the most recent rows.
      [newest | _] = all = Billing.list_user_invoices(user.uuid)
      assert [^newest] = Billing.list_user_invoices(user.uuid, %{limit: 1})
      assert length(all) == 4
    end
  end

  # ── Billing profiles ────────────────────────────────────────────

  describe "billing profiles" do
    test "create_billing_profile/2 makes the first profile default" do
      user = fixture_user()

      assert {:ok, profile} =
               Billing.create_billing_profile(user, %{
                 "type" => "individual",
                 "first_name" => "Jane",
                 "last_name" => "Roe",
                 "country" => "EE"
               })

      assert profile.is_default == true
    end

    test "create_billing_profile/2 returns error for invalid type" do
      user = fixture_user()

      assert {:error, cs} =
               Billing.create_billing_profile(user, %{"type" => "company"})

      assert %{company_name: [_ | _]} = errors_on(cs)
    end

    test "creating or updating a profile as default leaves the user one default" do
      user = fixture_user()
      {:ok, first} = Billing.create_billing_profile(user, profile_attrs("First"))
      {:ok, second} = Billing.create_billing_profile(user, profile_attrs("Second"))
      refute second.is_default

      {:ok, third} =
        Billing.create_billing_profile(user, Map.put(profile_attrs("Third"), "is_default", true))

      assert default_uuids(user) == [third.uuid]

      {:ok, _} = Billing.update_billing_profile(second, %{"is_default" => true})
      assert default_uuids(user) == [second.uuid]
      assert Billing.get_default_billing_profile(user).uuid == second.uuid

      # Another user's default is left alone.
      other = fixture_user()
      {:ok, others} = Billing.create_billing_profile(other, profile_attrs("Other"))
      {:ok, _} = Billing.update_billing_profile(first, %{"is_default" => true})
      assert default_uuids(other) == [others.uuid]
    end

    test "a failed save as default keeps the current default" do
      user = fixture_user()
      {:ok, first} = Billing.create_billing_profile(user, profile_attrs("First"))
      {:ok, second} = Billing.create_billing_profile(user, profile_attrs("Second"))

      assert {:error, _} =
               Billing.update_billing_profile(second, %{"is_default" => true, "type" => "bogus"})

      assert default_uuids(user) == [first.uuid]
    end

    test "get_default_billing_profile/1 does not raise on duplicate defaults" do
      user = fixture_user()
      {:ok, first} = Billing.create_billing_profile(user, profile_attrs("First"))
      {:ok, second} = Billing.create_billing_profile(user, profile_attrs("Second"))

      # Data saved before defaults were kept unique.
      Repo.update_all(
        from(bp in BillingProfile, where: bp.uuid == ^second.uuid),
        set: [is_default: true, updated_at: DateTime.add(first.updated_at, 60)]
      )

      assert Billing.get_default_billing_profile(user).uuid == second.uuid
    end
  end

  defp profile_attrs(first_name) do
    %{"type" => "individual", "first_name" => first_name, "last_name" => "Roe", "country" => "EE"}
  end

  defp default_uuids(user) do
    Repo.all(
      from(bp in BillingProfile,
        where: bp.user_uuid == ^user.uuid and bp.is_default == true,
        select: bp.uuid
      )
    )
  end

  # ── Subscription types & subscriptions ──────────────────────────

  describe "subscription types" do
    test "create / get / update / list" do
      assert {:ok, type} =
               Billing.create_subscription_type(%{
                 name: "Pro",
                 slug: "pro-#{uniq()}",
                 price: Decimal.new("29.99")
               })

      assert {:ok, ^type} = Billing.get_subscription_type(type.uuid)
      assert {:ok, updated} = Billing.update_subscription_type(type, %{name: "Pro Plus"})
      assert updated.name == "Pro Plus"
      assert Enum.any?(Billing.list_subscription_types(), &(&1.uuid == type.uuid))
    end

    test "get_subscription_type/1 returns error for missing" do
      assert {:error, :subscription_type_not_found} = Billing.get_subscription_type("not-a-uuid")
    end

    test "create_subscription_type/1 invalid attrs" do
      assert {:error, cs} = Billing.create_subscription_type(%{name: "", slug: "", price: nil})
      assert %{name: [_ | _], slug: [_ | _], price: [_ | _]} = errors_on(cs)
    end
  end

  describe "subscriptions" do
    # These tests were `@tag :skip` while a from-scratch build of
    # `phoenix_kit_subscriptions` lacked `subscription_type_uuid`. It exists
    # (core's chain creates it), so they run; the non-persisting error paths
    # below never needed it.

    test "create_subscription/2 with unknown type returns error (no insert)" do
      user = fixture_user()

      assert {:error, :subscription_type_not_found} =
               Billing.create_subscription(user.uuid, %{subscription_type_uuid: "not-a-uuid"})
    end

    test "get_subscription/2 returns nil for a non-uuid (no insert)" do
      assert Billing.get_subscription("not-a-uuid") == nil
    end

    test "create_subscription/2 with no trial is active" do
      user = fixture_user()

      {:ok, type} =
        Billing.create_subscription_type(%{
          name: "Pro",
          slug: "pro-#{uniq()}",
          price: Decimal.new("29.99")
        })

      assert {:ok, sub} =
               Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})

      assert sub.status == "active"
    end

    test "status transitions: cancel / pause / resume" do
      user = fixture_user()

      {:ok, type} =
        Billing.create_subscription_type(%{
          name: "Pro",
          slug: "pro-#{uniq()}",
          price: Decimal.new("29.99")
        })

      {:ok, sub} = Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})
      assert {:ok, paused} = Billing.pause_subscription(sub)
      assert paused.status == "paused"
      assert {:ok, resumed} = Billing.resume_subscription(paused)
      assert resumed.status == "active"
      assert {:ok, cancelled} = Billing.cancel_subscription(resumed, immediately: true)
      assert cancelled.status == "cancelled"
    end

    test "edit-save persists a changed payment method" do
      # Mirrors the SubscriptionForm edit-save path: when an admin changes
      # the payment method (and optionally the type) in edit mode, the new
      # `payment_method_uuid` must persist via `update_subscription/2`
      # (the form routes payment-method changes through it). Guards PR #3
      # review #10 (edit-save previously ignored payment-method changes).
      user = fixture_user()

      {:ok, type} =
        Billing.create_subscription_type(%{
          name: "Pro",
          slug: "pro-#{uniq()}",
          price: Decimal.new("29.99")
        })

      {:ok, pm} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: user.uuid,
          type: "card",
          brand: "visa",
          last4: "4242"
        })

      {:ok, sub} = Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})
      assert is_nil(sub.payment_method_uuid)

      assert {:ok, updated} =
               Billing.update_subscription(sub, %{payment_method_uuid: pm.uuid})

      assert updated.payment_method_uuid == pm.uuid

      reloaded = Billing.get_subscription(sub.uuid)
      assert reloaded.payment_method_uuid == pm.uuid
    end
  end

  describe "list_payment_methods/2 scoping (payment-method guard)" do
    # Pins the property the SubscriptionForm edit-save guard relies on to
    # reject a crafted/stale payment_method_uuid: the list is scoped to the
    # user and to active methods only. (Subscription persistence is blocked
    # by the core column gap, so the guard's user-scoping is pinned here at
    # the context level, where it actually lives.)
    test "returns only the given user's active methods" do
      user_a = fixture_user()
      user_b = fixture_user()

      {:ok, pm_a} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: user_a.uuid,
          type: "card",
          status: "active"
        })

      {:ok, _pm_a_removed} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: user_a.uuid,
          type: "card",
          status: "removed"
        })

      # user_b's active method exists but must never appear in user_a's list.
      {:ok, _pm_b} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: user_b.uuid,
          type: "card",
          status: "active"
        })

      methods = Billing.list_payment_methods(user_a.uuid, status: "active")

      # Scoped to user_a's single active method: the exact-list pattern-match
      # pins count == 1, and pinning that one to pm_a rules out user_b's method
      # and the "removed" one in a single assertion.
      assert [%{uuid: only_uuid}] = methods
      assert only_uuid == pm_a.uuid
    end

    test "status: filters by the exact status (not just the active_only default)" do
      user = fixture_user()

      {:ok, _active} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: user.uuid,
          type: "card",
          status: "active"
        })

      {:ok, removed} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: user.uuid,
          type: "card",
          status: "removed"
        })

      assert [%{uuid: removed_uuid}] = Billing.list_payment_methods(user.uuid, status: "removed")
      assert removed_uuid == removed.uuid
    end
  end

  describe "create_subscription/2 payment-method guard (context enforcement)" do
    # The ownership/active guard lives in the context, not only in the
    # SubscriptionForm LiveView, so every caller is covered. These pin the
    # reject path, which short-circuits before any subscription insert — so
    # they don't hit the core subscription_type_uuid column gap that blocks
    # the happy-path subscription tests.
    test "rejects a payment method belonging to another user" do
      user = fixture_user()
      other = fixture_user()

      {:ok, foreign} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: other.uuid,
          type: "card",
          status: "active"
        })

      assert {:error, :payment_method_not_usable} =
               Billing.create_subscription(user.uuid, %{
                 subscription_type_uuid: Ecto.UUID.generate(),
                 payment_method_uuid: foreign.uuid
               })
    end

    test "rejects the user's own non-active (removed) payment method" do
      user = fixture_user()

      {:ok, removed} =
        Billing.create_payment_method(%{
          provider: "manual",
          provider_payment_method_id: "pm_#{uniq()}",
          user_uuid: user.uuid,
          type: "card",
          status: "removed"
        })

      assert {:error, :payment_method_not_usable} =
               Billing.create_subscription(user.uuid, %{
                 subscription_type_uuid: Ecto.UUID.generate(),
                 payment_method_uuid: removed.uuid
               })
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp create_basic_order(user) do
    Billing.create_order(user, %{
      "total" => Decimal.new("99.00"),
      "currency" => "EUR",
      "billing_snapshot" => %{"email" => "g@example.com"},
      "line_items" => [%{"name" => "Item", "total" => "99.00"}]
    })
  end

  defp uniq, do: System.unique_integer([:positive])
end
