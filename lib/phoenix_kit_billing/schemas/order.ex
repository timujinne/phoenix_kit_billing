defmodule PhoenixKitBilling.Order do
  @moduledoc """
  Order schema for PhoenixKit Billing system.

  Manages orders with line items, amounts, and billing information.
  Orders serve as the primary document for tracking what users purchased.

  ## Schema Fields

  ### Identity & Relations
  - `user_uuid`: Foreign key to the user who placed the order
  - `billing_profile_uuid`: Foreign key to the billing profile used
  - `order_number`: Unique order identifier (e.g., "ORD-2024-0001")
  - `status`: Order status workflow

  ### Payment
  - `payment_method`: Payment method (Phase 1: "bank" only)
  - `currency`: ISO 4217 currency code
  - `base_currency`: The shop's base currency, frozen at order creation
  - `exchange_rate`: The rate `base_currency -> currency` the order was
    priced at, frozen at order creation
  - `base_total`: `total` expressed in `base_currency`, frozen at order
    creation

  ### Line Items
  - `line_items`: JSONB array of items purchased

  ### Financial
  - `subtotal`: Sum of line items before tax/discount
  - `tax_amount`: Calculated tax amount
  - `tax_rate`: Applied tax rate (0.20 = 20%)
  - `discount_amount`: Discount applied
  - `discount_code`: Coupon/referral code used
  - `total`: Final amount to be paid

  ### Snapshots & Notes
  - `billing_snapshot`: Copy of billing profile at order time
  - `notes`: Customer-visible notes
  - `internal_notes`: Admin-only notes

  ## Revision and external sync

  Two keys of `metadata` belong to billing and cannot be set through
  `changeset/2` or `status_changeset/2`:

  - `"revision"`: a counter of the changes an external system cares about. A
    new order starts at 1 (an order stored before the counter existed reads as
    1). Every update that changes the status, the order number, the buyer, the
    line items, an amount, the currency, the payment, the notes, the billing
    details, a confirmation, payment or cancellation time, or any other
    `metadata` key adds 1. `internal_notes` and the frozen `base_*` figures do
    not move it. The increment is made under a row lock, so two concurrent
    updates both count. `revision/1` reads it.
  - `"sync"`: the external system's mark for the order, written only by
    `PhoenixKitBilling.put_order_sync/2`, which touches neither `revision` nor
    `updated_at`. `sync/1` reads it and `where_sync/2` filters on it.

  A mark belongs to the revision it was written for. When the order changes
  afterwards its revision is higher than the mark's, and `sync/1` reports the
  order as `"pending"` again (keeping the external id and number it already
  has), so the external system knows to take it again.

  ## Status Workflow

  ```
  draft → pending → confirmed → paid
                 ↘         ↘
               cancelled   refunded
  ```

  ## Line Item Structure

  ```json
  [
    {
      "name": "Pro Plan - Monthly",
      "description": "Professional subscription plan",
      "quantity": 1,
      "unit_price": "99.00",
      "total": "99.00",
      "sku": "PLAN-PRO-M"
    }
  ]
  ```

  ## Usage Examples

      # Create an order
      {:ok, order} = Billing.create_order(user, %{
        billing_profile_uuid: profile.uuid,
        currency: "EUR",
        line_items: [
          %{name: "Pro Plan", quantity: 1, unit_price: "99.00", total: "99.00"}
        ],
        subtotal: "99.00",
        total: "99.00"
      })

      # Confirm order
      {:ok, order} = Billing.confirm_order(order)

      # Mark as paid
      {:ok, order} = Billing.mark_order_paid(order)
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset
  import Ecto.Query, warn: false

  @type t :: %__MODULE__{}

  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitBilling.BillingProfile

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_statuses ~w(draft pending confirmed paid cancelled refunded)
  @valid_payment_methods ~w(bank stripe paypal razorpay)

  schema "phoenix_kit_orders" do
    field(:order_number, :string)
    field(:status, :string, default: "draft")
    field(:payment_method, :string)

    # Line items (JSONB)
    field(:line_items, {:array, :map}, default: [])

    # Financial
    field(:subtotal, :decimal, default: Decimal.new("0"))
    field(:tax_amount, :decimal, default: Decimal.new("0"))
    field(:tax_rate, :decimal, default: Decimal.new("0"))
    field(:discount_amount, :decimal, default: Decimal.new("0"))
    field(:discount_code, :string)
    field(:total, :decimal)
    field(:currency, :string)

    # Frozen at order creation (§4.5, §9.1): the shop's base currency and
    # the rate the order was actually priced at, plus the total expressed
    # in that base currency. The columns are added by this package's own
    # `PhoenixKitBilling.Migrations` chain (V3), not a core migration —
    # see that module's moduledoc for why. Nullable, with no backfill of
    # existing rows: nothing downstream requires them populated, and a
    # pre-V3 or pre-E1 order simply has them come back nil.
    field(:base_currency, :string)
    field(:exchange_rate, :decimal)
    field(:base_total, :decimal)

    # Snapshots
    field(:billing_snapshot, :map, default: %{})

    # Notes
    field(:notes, :string)
    field(:internal_notes, :string)

    field(:metadata, :map, default: %{})

    # Timestamps
    field(:confirmed_at, :utc_datetime)
    field(:paid_at, :utc_datetime)
    field(:cancelled_at, :utc_datetime)

    # User reference (cross-package — FK constraint in core migrations)
    field(:user_uuid, UUIDv7)

    belongs_to(:user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7,
      define_field: false
    )

    # The operator-configured method the customer actually chose. Distinct
    # from `payment_method`, which is the small closed vocabulary above:
    # several options can share one method ("Bank transfer (EU)" and
    # "(UK)" are both `bank`), and an option can be renamed or deactivated
    # after the order is placed. ON DELETE SET NULL (core V162) so removing
    # an option neither fails nor rewrites history.
    belongs_to(:payment_option, PhoenixKitBilling.PaymentOption,
      foreign_key: :payment_option_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:billing_profile, BillingProfile,
      foreign_key: :billing_profile_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:invoices, PhoenixKitBilling.Invoice,
      foreign_key: :order_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for order creation.
  """
  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :user_uuid,
      :billing_profile_uuid,
      :order_number,
      :status,
      :payment_method,
      :payment_option_uuid,
      :line_items,
      :subtotal,
      :tax_amount,
      :tax_rate,
      :discount_amount,
      :discount_code,
      :total,
      :currency,
      :base_currency,
      :exchange_rate,
      :base_total,
      :billing_snapshot,
      :notes,
      :internal_notes,
      :metadata,
      :confirmed_at,
      :paid_at,
      :cancelled_at
    ])
    |> validate_required([:total, :currency])
    |> validate_guest_order_billing()
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_payment_method()
    |> validate_length(:currency, is: 3)
    |> validate_length(:base_currency, is: 3)
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> validate_number(:subtotal, greater_than_or_equal_to: 0)
    |> validate_number(:tax_amount, greater_than_or_equal_to: 0)
    |> validate_number(:discount_amount, greater_than_or_equal_to: 0)
    |> validate_line_items()
    |> maybe_generate_order_number()
    |> track_revision()
    |> unique_constraint(:order_number, name: :phoenix_kit_orders_order_number_uidx)
    # Named explicitly — see the note in `Invoice.changeset/2`.
    |> foreign_key_constraint(:user_uuid, name: :fk_orders_user_uuid)
    |> foreign_key_constraint(:billing_profile_uuid,
      name: :fk_orders_billing_profile_uuid
    )
  end

  # Guest orders must have billing_snapshot with email when no billing_profile_uuid
  defp validate_guest_order_billing(changeset) do
    billing_profile_uuid = get_field(changeset, :billing_profile_uuid)
    billing_snapshot = get_field(changeset, :billing_snapshot)

    cond do
      # Has billing profile - OK
      not is_nil(billing_profile_uuid) ->
        changeset

      # No billing profile but has billing snapshot with email - OK (guest order)
      is_map(billing_snapshot) and is_binary(billing_snapshot["email"]) and
          billing_snapshot["email"] != "" ->
        changeset

      # No billing profile and no valid billing snapshot - error
      true ->
        add_error(changeset, :billing_snapshot, "must have email for guest orders")
    end
  end

  @doc """
  Changeset for status transitions.
  """
  def status_changeset(order, new_status) do
    changeset =
      order
      |> change(status: new_status)
      |> validate_status_transition(order.status, new_status)
      |> track_revision()

    case new_status do
      "confirmed" ->
        put_change(changeset, :confirmed_at, UtilsDate.utc_now())

      "paid" ->
        put_change(changeset, :paid_at, UtilsDate.utc_now())

      "cancelled" ->
        put_change(changeset, :cancelled_at, UtilsDate.utc_now())

      _ ->
        changeset
    end
  end

  defp validate_status_transition(changeset, from, to) do
    valid_transitions = %{
      "draft" => ~w(pending confirmed cancelled),
      "pending" => ~w(confirmed cancelled),
      "confirmed" => ~w(paid cancelled refunded),
      "paid" => ~w(refunded),
      "cancelled" => [],
      "refunded" => []
    }

    allowed = Map.get(valid_transitions, from, [])

    if to in allowed do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{from} to #{to}")
    end
  end

  # Validate payment_method only when provided (nil is allowed)
  defp validate_payment_method(changeset) do
    case get_field(changeset, :payment_method) do
      nil -> changeset
      _ -> validate_inclusion(changeset, :payment_method, @valid_payment_methods)
    end
  end

  defp validate_line_items(changeset) do
    items = get_field(changeset, :line_items) || []

    errors =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, idx} ->
        cond do
          not is_map(item) ->
            ["Item #{idx + 1}: must be a map"]

          not Map.has_key?(item, "name") and not Map.has_key?(item, :name) ->
            ["Item #{idx + 1}: missing name"]

          true ->
            []
        end
      end)

    if errors == [] do
      changeset
    else
      add_error(changeset, :line_items, Enum.join(errors, "; "))
    end
  end

  defp maybe_generate_order_number(changeset) do
    if get_field(changeset, :order_number) do
      changeset
    else
      # Will be set by context with proper prefix from settings
      changeset
    end
  end

  # -- revision and external sync ---------------------------------------------

  # Metadata keys billing owns: no changeset can set, replace or drop them.
  @owned_metadata_keys ~w(revision sync)

  # What an external system reads of an order. `internal_notes` and the frozen
  # `base_*` figures are not among them.
  @revision_fields ~w(status order_number user_uuid payment_method payment_option_uuid line_items
                      subtotal tax_amount tax_rate discount_amount discount_code total currency
                      billing_profile_uuid billing_snapshot notes confirmed_at paid_at
                      cancelled_at)a

  @doc """
  The revision of an order: how many times it changed in a way an external
  system cares about, counting its creation. See the moduledoc.
  """
  @spec revision(t()) :: pos_integer()
  def revision(%__MODULE__{metadata: metadata}), do: revision_of(metadata)

  defp revision_of(%{"revision" => revision}) when is_integer(revision) and revision > 0,
    do: revision

  defp revision_of(_metadata), do: 1

  @doc """
  What the external system's mark says about the order now.

  Returns a map with string keys `"state"`, `"external_id"`, `"external_number"`,
  `"external_status"`, `"synced_at"`, `"error"` and `"revision"` (the order's
  current revision).

  `"state"` is `"synced"` or `"failed"` only while the mark was written for the
  order's current revision; an order without a mark, or one that changed after
  it was marked, is `"pending"`. A mark's `"error"` is shown only with the
  `"failed"` state it explains.
  """
  @spec sync(t()) :: map()
  def sync(%__MODULE__{metadata: metadata} = order) do
    current = revision(order)
    stored = if is_map(metadata["sync"]), do: metadata["sync"], else: %{}

    settled? =
      stored["state"] in ~w(synced failed) and is_integer(stored["revision"]) and
        stored["revision"] == current

    state = if settled?, do: stored["state"], else: "pending"

    %{
      "state" => state,
      "external_id" => stored["external_id"],
      "external_number" => stored["external_number"],
      "external_status" => stored["external_status"],
      "synced_at" => stored["synced_at"],
      "error" => if(state == "failed", do: stored["error"]),
      "revision" => current
    }
  end

  # Whether the mark was written for the order's current revision. A stored
  # revision that is not a positive whole number reads as none (the mark is
  # not current) instead of failing the cast and the whole query; the order's
  # own revision then reads as 1, as `revision/1` does.
  defmacrop sync_revision_current?(metadata) do
    quote do
      fragment(
        """
        CASE WHEN jsonb_typeof(?->'sync'->'revision') = 'number'
                  AND (?->'sync'->'revision')::text ~ '^[1-9][0-9]*$'
             THEN (?->'sync'->'revision')::text::numeric
        END = coalesce(
          CASE WHEN jsonb_typeof(?->'revision') = 'number'
                    AND (?->'revision')::text ~ '^[1-9][0-9]*$'
               THEN (?->'revision')::text::numeric
          END, 1)
        """,
        unquote(metadata),
        unquote(metadata),
        unquote(metadata),
        unquote(metadata),
        unquote(metadata),
        unquote(metadata)
      )
    end
  end

  @doc """
  Narrows an `Order` query to orders whose `sync/1` state is `:pending` or
  `:synced`; `:any` leaves it alone. A `failed` order is in neither narrowed
  set until it changes again.
  """
  @spec where_sync(Ecto.Queryable.t(), :pending | :synced | :any) :: Ecto.Query.t()
  def where_sync(query, :any), do: from(o in query)

  def where_sync(query, :synced) do
    from(o in query,
      where:
        fragment("?->'sync'->>'state'", o.metadata) == "synced" and
          sync_revision_current?(o.metadata)
    )
  end

  def where_sync(query, :pending) do
    from(o in query,
      where:
        not fragment(
          "coalesce(?->'sync'->>'state' IN ('synced', 'failed') AND ?, false)",
          o.metadata,
          sync_revision_current?(o.metadata)
        )
    )
  end

  # A new order starts at revision 1. An update that changes what an external
  # system reads adds 1, counted on the locked row so concurrent updates both
  # count. Whatever the attrs say, `sync` and `revision` stay as stored.
  defp track_revision(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset) do
    metadata = get_field(changeset, :metadata) || %{}
    put_change(changeset, :metadata, metadata |> Map.delete("sync") |> Map.put("revision", 1))
  end

  defp track_revision(%Ecto.Changeset{} = changeset) do
    changeset = keep_owned_metadata(changeset)

    if revision_relevant?(changeset),
      do: prepare_changes(changeset, &bump_revision/1),
      else: changeset
  end

  defp keep_owned_metadata(changeset) do
    case fetch_change(changeset, :metadata) do
      {:ok, %{} = metadata} ->
        owned = Map.take(changeset.data.metadata || %{}, @owned_metadata_keys)

        put_change(
          changeset,
          :metadata,
          metadata |> Map.drop(@owned_metadata_keys) |> Map.merge(owned)
        )

      _ ->
        changeset
    end
  end

  defp revision_relevant?(changeset) do
    Enum.any?(@revision_fields, &Map.has_key?(changeset.changes, &1)) or
      Map.has_key?(changeset.changes, :metadata)
  end

  defp bump_revision(changeset) do
    uuid = changeset.data.uuid

    # NO KEY UPDATE: enough to serialize the counting (it conflicts with itself
    # and with the UPDATE that follows), and unlike FOR UPDATE it does not
    # conflict with the FOR KEY SHARE an invoice insert takes on the order.
    stored =
      from(o in __MODULE__,
        where: o.uuid == ^uuid,
        lock: "FOR NO KEY UPDATE",
        select: o.metadata
      )
      |> changeset.repo.one()
      |> Kernel.||(%{})

    base =
      case fetch_change(changeset, :metadata) do
        {:ok, %{} = metadata} -> metadata
        _ -> stored
      end

    owned = stored |> Map.take(["sync"]) |> Map.put("revision", revision_of(stored) + 1)

    put_change(changeset, :metadata, base |> Map.drop(@owned_metadata_keys) |> Map.merge(owned))
  end

  @doc """
  Calculates totals from line items.

  Returns `{subtotal, tax_amount, total}` as Decimals.
  """
  def calculate_totals(line_items, tax_rate \\ Decimal.new("0"), discount \\ Decimal.new("0")) do
    subtotal =
      line_items
      |> Enum.reduce(Decimal.new("0"), fn item, acc ->
        item_total =
          item
          |> Map.get("total", Map.get(item, :total, "0"))
          |> to_decimal()

        Decimal.add(acc, item_total)
      end)

    taxable = Decimal.sub(subtotal, discount)
    tax_amount = Decimal.mult(taxable, tax_rate) |> Decimal.round(2)
    total = Decimal.add(taxable, tax_amount)

    {subtotal, tax_amount, total}
  end

  @doc """
  Calculates totals with automatic tax rate from country.

  Uses standard VAT rate from BeamLabCountries based on the billing country.
  Returns `{subtotal, tax_amount, total}` as Decimals.

  ## Examples

      iex> items = [%{"total" => "100.00"}]
      iex> {subtotal, tax, total} = Order.calculate_totals_for_country(items, "EE")
      iex> Decimal.to_string(tax)
      "20.00"
      iex> Decimal.to_string(total)
      "120.00"
  """
  def calculate_totals_for_country(line_items, country_code, discount \\ Decimal.new("0")) do
    tax_rate = CountryData.get_standard_vat_rate(country_code)
    calculate_totals(line_items, tax_rate, discount)
  end

  @doc """
  Gets the standard VAT rate for a country as a Decimal.

  ## Examples

      iex> Order.get_country_tax_rate("EE")
      #Decimal<0.20>

      iex> Order.get_country_tax_rate("US")
      #Decimal<0>
  """
  def get_country_tax_rate(country_code) do
    CountryData.get_standard_vat_rate(country_code)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  @doc """
  Checks if order can be edited (is in draft or pending status).
  """
  def editable?(%__MODULE__{status: status}) when status in ~w(draft pending), do: true
  def editable?(_), do: false

  @doc """
  Checks if order can be cancelled.
  """
  def cancellable?(%__MODULE__{status: status}) when status in ~w(draft pending confirmed),
    do: true

  def cancellable?(_), do: false

  @doc """
  Checks if order can be marked as paid.
  """
  def payable?(%__MODULE__{status: "confirmed"}), do: true
  def payable?(_), do: false

  @doc """
  Returns human-readable status label.
  """
  def status_label("draft"), do: "Draft"
  def status_label("pending"), do: "Pending"
  def status_label("confirmed"), do: "Confirmed"
  def status_label("paid"), do: "Paid"
  def status_label("cancelled"), do: "Cancelled"
  def status_label("refunded"), do: "Refunded"
  def status_label(_), do: "Unknown"

  @doc """
  Returns status badge color class.
  """
  def status_color("draft"), do: "badge-neutral"
  def status_color("pending"), do: "badge-warning"
  def status_color("confirmed"), do: "badge-info"
  def status_color("paid"), do: "badge-success"
  def status_color("cancelled"), do: "badge-error"
  def status_color("refunded"), do: "badge-secondary"
  def status_color(_), do: "badge-ghost"
end
