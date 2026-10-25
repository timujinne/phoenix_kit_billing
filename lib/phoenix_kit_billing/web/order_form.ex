defmodule PhoenixKitBilling.Web.OrderForm do
  @moduledoc """
  Order form LiveView for creating and editing orders.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.DecimalInput
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Number
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Errors
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Paths
  alias PhoenixKitBilling.Web.Trail

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      # Per phoenix-thinking iron law: no DB in mount (called twice on
      # dead + live render). Defer all reads to handle_params.
      {:ok,
       socket
       |> assign(:project_title, nil)
       |> assign(:users, [])
       |> assign(:currencies, [])
       # No DB in mount (see above), so no real currency to offer yet —
       # `nil`, not a currency literal (§3.3). `handle_params/3` sets the
       # real base currency before `load_order/2` ever reads this assign,
       # so no changeset is ever built against this placeholder.
       |> assign(:default_currency, nil)
       |> assign(:billing_profiles, [])
       |> assign(:order, nil)
       |> assign(:form, nil)
       |> assign(:line_items, [])
       |> assign(:selected_user_uuid, nil)
       |> assign(:selected_billing_profile_uuid, nil)
       |> assign(:country_tax_rate, nil)
       |> assign(:country_name, nil)
       |> assign(:country_vat_percent, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    project_title = Settings.get_project_title()
    %{users: users} = Auth.list_users_paginated(limit: 100)
    currencies = Billing.list_currencies(enabled: true)
    # §3.3: base = is_default row (billing_default_currency is no longer read)
    default_currency = (Billing.get_base_currency() || %{code: nil}).code

    socket =
      socket
      |> assign(:project_title, project_title)
      |> assign(:users, users)
      |> assign(:currencies, currencies)
      |> assign(:default_currency, default_currency)
      |> load_order(params["id"])

    {:noreply, socket}
  end

  defp load_order(socket, nil) do
    # New order
    changeset =
      Billing.change_order(%Billing.Order{
        currency: socket.assigns.default_currency,
        line_items: [%{"name" => "", "quantity" => 1, "unit_price" => "0.00", "total" => "0.00"}]
      })

    socket
    |> Trail.billing(gettext("New order"), [Trail.orders()])
    |> assign(:order, nil)
    |> assign(:form, to_form(changeset))
    |> assign(:line_items, [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}])
    |> assign(:selected_user_uuid, nil)
    |> assign(:selected_billing_profile_uuid, nil)
    |> assign(:country_tax_rate, nil)
    |> assign(:country_name, nil)
    |> assign(:country_vat_percent, nil)
  end

  defp load_order(socket, id) do
    case Billing.get_order(id, preload: [:billing_profile]) do
      nil ->
        socket
        |> put_flash(:error, gettext("Order not found"))
        |> push_navigate(to: Routes.path("/admin/billing/orders"))

      order ->
        changeset = Billing.change_order(order)
        line_items = parse_line_items(order.line_items)

        billing_profiles =
          if order.user_uuid, do: Billing.list_user_billing_profiles(order.user_uuid), else: []

        # Get country tax info from billing profile
        {country_tax_rate, country_name, country_vat_percent} =
          if order.billing_profile do
            get_country_tax_info(order.billing_profile.country)
          else
            {nil, nil, nil}
          end

        socket
        |> Trail.billing(gettext("Edit"), [
          Trail.orders(),
          Trail.crumb(order.order_number, Paths.order_detail(order.uuid))
        ])
        |> assign(:order, order)
        |> assign(:form, to_form(changeset))
        |> assign(:line_items, line_items)
        |> assign(:selected_user_uuid, order.user_uuid)
        |> assign(:billing_profiles, billing_profiles)
        |> assign(:selected_billing_profile_uuid, order.billing_profile_uuid)
        |> assign(:country_tax_rate, country_tax_rate)
        |> assign(:country_name, country_name)
        |> assign(:country_vat_percent, country_vat_percent)
    end
  end

  defp parse_line_items(nil),
    do: [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}]

  defp parse_line_items([]),
    do: [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}]

  defp parse_line_items(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      %{
        id: idx,
        name: item["name"] || "",
        description: item["description"] || "",
        quantity: item["quantity"] || 1,
        unit_price: item["unit_price"] || "0.00"
      }
    end)
  end

  @impl true
  def handle_event("select_user", %{"user_uuid" => user_uuid}, socket) do
    user_uuid = if user_uuid == "", do: nil, else: user_uuid
    billing_profiles = if user_uuid, do: Billing.list_user_billing_profiles(user_uuid), else: []

    # Auto-select default profile if available, otherwise select first profile
    default_profile = Enum.find(billing_profiles, & &1.is_default)
    selected_profile = default_profile || List.first(billing_profiles)
    selected_profile_uuid = if selected_profile, do: selected_profile.uuid, else: nil

    # Get country tax info for selected profile
    {country_tax_rate, country_name, country_vat_percent} =
      if selected_profile do
        get_country_tax_info(selected_profile.country)
      else
        {nil, nil, nil}
      end

    {:noreply,
     socket
     |> assign(:selected_user_uuid, user_uuid)
     |> assign(:billing_profiles, billing_profiles)
     |> assign(:selected_billing_profile_uuid, selected_profile_uuid)
     |> assign(:country_tax_rate, country_tax_rate)
     |> assign(:country_name, country_name)
     |> assign(:country_vat_percent, country_vat_percent)}
  end

  @impl true
  def handle_event(
        "select_billing_profile",
        %{"order" => %{"billing_profile_uuid" => profile_uuid}},
        socket
      ) do
    handle_billing_profile_selection(profile_uuid, socket)
  end

  @impl true
  def handle_event("select_billing_profile", %{"profile_uuid" => profile_uuid}, socket) do
    handle_billing_profile_selection(profile_uuid, socket)
  end

  @impl true
  def handle_event("add_line_item", _params, socket) do
    new_id = length(socket.assigns.line_items)
    new_item = %{id: new_id, name: "", description: "", quantity: 1, unit_price: "0.00"}
    {:noreply, assign(socket, :line_items, socket.assigns.line_items ++ [new_item])}
  end

  @impl true
  def handle_event("remove_line_item", %{"id" => id}, socket) do
    id = String.to_integer(id)
    items = Enum.reject(socket.assigns.line_items, &(&1.id == id))

    items =
      if Enum.empty?(items),
        do: [%{id: 0, name: "", description: "", quantity: 1, unit_price: "0.00"}],
        else: items

    {:noreply, assign(socket, :line_items, items)}
  end

  @impl true
  def handle_event("update_line_item", params, socket) do
    id = String.to_integer(params["id"])
    field = String.to_existing_atom(params["field"])
    value = params["value"]

    items =
      Enum.map(socket.assigns.line_items, fn item ->
        if item.id == id do
          Map.put(item, field, value)
        else
          item
        end
      end)

    {:noreply, assign(socket, :line_items, items)}
  end

  @impl true
  def handle_event("save", %{"order" => order_params}, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      # Get tax rate - prefer country-based rate from billing profile, fallback to config
      tax_rate =
        case socket.assigns.country_tax_rate do
          %Decimal{} = rate ->
            rate

          _ ->
            config = Billing.get_config()
            get_tax_rate_decimal(config)
        end

      line_items =
        socket.assigns.line_items
        |> Enum.filter(&(&1.name != ""))
        |> Enum.map(fn item ->
          quantity = parse_number(item.quantity, 1)
          unit_price = parse_decimal(item.unit_price)
          total = Decimal.mult(unit_price, quantity)

          %{
            "name" => item.name,
            "description" => item.description,
            "quantity" => quantity,
            "unit_price" => Decimal.to_string(unit_price),
            "total" => Decimal.to_string(total)
          }
        end)

      # Calculate totals with tax using Order.calculate_totals
      {subtotal, tax_amount, total} =
        Order.calculate_totals(line_items, tax_rate, Decimal.new("0"))

      order_params =
        order_params
        |> Map.put("line_items", line_items)
        |> Map.put("subtotal", Decimal.to_string(subtotal))
        |> Map.put("tax_rate", Decimal.to_string(tax_rate))
        |> Map.put("tax_amount", Decimal.to_string(tax_amount))
        |> Map.put("total", Decimal.to_string(total))
        |> Map.put("user_uuid", socket.assigns.selected_user_uuid)
        |> Map.put("billing_profile_uuid", socket.assigns.selected_billing_profile_uuid)

      save_order(socket, order_params)
    end)
  end

  defp save_order(socket, params) do
    result =
      if socket.assigns.order do
        Billing.update_order(socket.assigns.order, params)
      else
        Billing.create_order(params)
      end

    case result do
      {:ok, order} ->
        action =
          if socket.assigns.order, do: "billing.order_updated", else: "billing.order_created"

        Activity.log(action,
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "order",
          resource_uuid: order.uuid,
          metadata: %{
            "order_number" => order.order_number,
            "status" => order.status,
            "currency" => order.currency
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Order saved successfully"))
         |> push_navigate(to: Routes.path("/admin/billing/orders/#{order.uuid}"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      # A refusal that is not about a field: an order in the trash, or one that
      # can no longer be edited.
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  rescue
    e ->
      require Logger
      Logger.error("Order save failed: #{Exception.message(e)}")
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  defp handle_billing_profile_selection(profile_uuid, socket) do
    profile_uuid = if profile_uuid == "", do: nil, else: profile_uuid

    {country_tax_rate, country_name, country_vat_percent} =
      if profile_uuid do
        case Billing.get_billing_profile(profile_uuid) do
          nil -> {nil, nil, nil}
          profile -> get_country_tax_info(profile.country)
        end
      else
        {nil, nil, nil}
      end

    {:noreply,
     socket
     |> assign(:selected_billing_profile_uuid, profile_uuid)
     |> assign(:country_tax_rate, country_tax_rate)
     |> assign(:country_name, country_name)
     |> assign(:country_vat_percent, country_vat_percent)}
  end

  defp parse_number(value, _default) when is_integer(value), do: value

  defp parse_number(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_number(_, default), do: default

  defp parse_decimal(value) when is_binary(value) do
    case Number.parse_decimal(value) do
      {:ok, decimal} -> decimal
      {:error, _reason} -> Decimal.new(0)
    end
  end

  defp parse_decimal(_), do: Decimal.new(0)

  defp get_tax_rate_decimal(config) do
    if config.tax_enabled do
      # Settings stores "20" for 20%, schema needs 0.20
      config.default_tax_rate
      |> Decimal.new()
      |> Decimal.div(Decimal.new(100))
    else
      Decimal.new("0")
    end
  end

  defp get_country_tax_info(nil), do: {nil, nil, nil}

  defp get_country_tax_info(country_code) when is_binary(country_code) do
    tax_rate = CountryData.get_standard_vat_rate(country_code)
    vat_percent = CountryData.get_standard_vat_percent(country_code)
    country_name = CountryData.get_country_name(country_code)

    {tax_rate, country_name, vat_percent}
  end

  defp get_country_tax_info(_), do: {nil, nil, nil}
end
