defmodule PhoenixKitBilling.Schemas.TrashFieldsTest do
  @moduledoc """
  The trash columns on `Order` and `Invoice` are billing's own: only the trash
  functions write them. A form, a crafted submit or any caller of
  `create_*`/`update_*` passes operator-supplied params to `changeset/2`, which
  must neither set nor clear them.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.{Invoice, Order}

  @now ~U[2026-03-01 10:00:00Z]
  @actor "0192f6e0-0000-7000-8000-000000000001"

  defp loaded(struct, fields), do: Ecto.put_meta(struct(struct, fields), state: :loaded)

  @order_attrs %{
    "total" => "5.00",
    "currency" => "EUR",
    "billing_snapshot" => %{"email" => "g@example.com"}
  }

  @invoice_attrs %{
    "total" => "5.00",
    "currency" => "EUR",
    "billing_details" => %{"email" => "g@example.com"}
  }

  describe "fields" do
    test "both schemas carry trashed_at and trashed_by_uuid, nil by default" do
      for module <- [Order, Invoice] do
        assert :trashed_at in module.__schema__(:fields)
        assert :trashed_by_uuid in module.__schema__(:fields)
        assert module.__schema__(:type, :trashed_at) == :utc_datetime
        assert %{trashed_at: nil, trashed_by_uuid: nil} = struct(module)
      end
    end
  end

  describe "changeset/2 cannot write them" do
    test "not on a new order or invoice" do
      forged = %{"trashed_at" => "2026-03-01T10:00:00Z", "trashed_by_uuid" => @actor}

      order = Order.changeset(%Order{}, Map.merge(@order_attrs, forged))
      invoice = Invoice.changeset(%Invoice{}, Map.merge(@invoice_attrs, forged))

      for changeset <- [order, invoice] do
        refute Map.has_key?(changeset.changes, :trashed_at)
        refute Map.has_key?(changeset.changes, :trashed_by_uuid)
      end
    end

    test "not on a stored one, and they cannot be cleared either" do
      order = loaded(Order, trashed_at: @now, trashed_by_uuid: @actor, status: "draft")
      invoice = loaded(Invoice, trashed_at: @now, trashed_by_uuid: @actor, status: "draft")

      clearing = %{"trashed_at" => nil, "trashed_by_uuid" => nil}
      forging = %{trashed_at: ~U[2030-01-01 00:00:00Z], trashed_by_uuid: Ecto.UUID.generate()}

      for {struct, attrs} <- [
            {order, clearing},
            {order, forging},
            {invoice, clearing},
            {invoice, forging}
          ] do
        module = struct.__struct__
        changeset = module.changeset(struct, attrs)

        refute Map.has_key?(changeset.changes, :trashed_at)
        refute Map.has_key?(changeset.changes, :trashed_by_uuid)
      end
    end
  end

  describe "trash_changeset/2 and restore_changeset/1" do
    test "set and clear exactly the two fields" do
      for module <- [Order, Invoice] do
        trashed = module.trash_changeset(struct(module), @actor)
        # updated_at is forced to what it is: trashing is not an edit.
        assert Map.keys(trashed.changes) |> Enum.sort() ==
                 [:trashed_at, :trashed_by_uuid, :updated_at]

        assert trashed.changes.trashed_by_uuid == @actor
        assert %DateTime{} = trashed.changes.trashed_at

        restored =
          module.restore_changeset(struct(module, trashed_at: @now, trashed_by_uuid: @actor))

        assert restored.changes == %{trashed_at: nil, trashed_by_uuid: nil, updated_at: nil}
      end
    end

    test "trashing without an actor stores none" do
      changeset = Order.trash_changeset(%Order{}, nil)
      assert %DateTime{} = changeset.changes.trashed_at
      refute Map.has_key?(changeset.changes, :trashed_by_uuid)
    end
  end

  describe "predicates" do
    test "trashed?/1" do
      refute Order.trashed?(%Order{})
      assert Order.trashed?(%Order{trashed_at: @now})
      refute Invoice.trashed?(%Invoice{})
      assert Invoice.trashed?(%Invoice{trashed_at: @now})
    end

    test "Invoice.open?/1 is false for a trashed invoice, as for a void one" do
      assert Invoice.open?(%Invoice{status: "draft"})
      refute Invoice.open?(%Invoice{status: "draft", trashed_at: @now})
      refute Invoice.open?(%Invoice{status: "void"})
    end

    test "Order.trashable?/1: a draft or a cancelled order that is not in the trash" do
      assert Order.trashable?(%Order{status: "draft"})
      assert Order.trashable?(%Order{status: "cancelled"})

      for status <- ~w(pending confirmed paid refunded) do
        refute Order.trashable?(%Order{status: status}), status
      end

      refute Order.trashable?(%Order{status: "draft", trashed_at: @now})
    end

    test "Invoice.trashable?/1: a draft never sent, not in the trash" do
      assert Invoice.trashable?(%Invoice{status: "draft"})
      refute Invoice.trashable?(%Invoice{status: "draft", sent_at: @now})
      refute Invoice.trashable?(%Invoice{status: "draft", trashed_at: @now})

      for status <- ~w(sent paid void overdue) do
        refute Invoice.trashable?(%Invoice{status: status}), status
      end
    end

    test "a trashed document offers no editing, cancelling, sending or voiding" do
      refute Order.editable?(%Order{status: "draft", trashed_at: @now})
      refute Order.cancellable?(%Order{status: "draft", trashed_at: @now})
      refute Invoice.editable?(%Invoice{status: "draft", trashed_at: @now})
      refute Invoice.sendable?(%Invoice{status: "draft", trashed_at: @now})
      refute Invoice.voidable?(%Invoice{status: "draft", trashed_at: @now})

      assert Order.editable?(%Order{status: "draft"})
      assert Order.cancellable?(%Order{status: "draft"})
      assert Invoice.editable?(%Invoice{status: "draft"})
      assert Invoice.sendable?(%Invoice{status: "draft"})
      assert Invoice.voidable?(%Invoice{status: "draft"})
    end

    test "void_offered? is voidable? without payments on the invoice" do
      paid_some = Decimal.new("40.00")

      assert Invoice.void_offered?(%Invoice{status: "sent", paid_amount: Decimal.new(0)})
      refute Invoice.void_offered?(%Invoice{status: "sent", paid_amount: paid_some})
      refute Invoice.void_offered?(%Invoice{status: "paid", paid_amount: Decimal.new(0)})

      refute Invoice.void_offered?(%Invoice{
               status: "draft",
               paid_amount: Decimal.new(0),
               trashed_at: @now
             })

      # voidable? looks at the status alone.
      assert Invoice.voidable?(%Invoice{status: "sent", paid_amount: paid_some})
    end
  end
end
