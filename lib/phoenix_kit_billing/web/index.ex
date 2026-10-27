defmodule PhoenixKitBilling.Web.Index do
  @moduledoc """
  Billing module dashboard LiveView.

  Provides an overview of billing activity including:
  - Key metrics (orders, invoices, revenue)
  - Recent orders and invoices
  - Quick actions
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TimeDisplay
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.InvoiceStatusBadge
  import PhoenixKitBilling.Web.Components.OrderStatusBadge

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Paths
  alias PhoenixKitBilling.Web.Authz
  alias PhoenixKitBilling.Web.Trail

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      socket =
        socket
        |> Trail.landing()
        |> assign_capabilities()
        |> assign(stats: nil, recent_orders: [], recent_invoices: [], currencies: [])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:project_title, Settings.get_project_title())
     |> load_dashboard_data()}
  end

  # The dashboard sits on the base "billing" key, so it shows a section only
  # to a holder of the capability that gates the same records elsewhere:
  # order figures need manage_orders, invoice and revenue figures
  # manage_invoices. Links point only where the viewer may go.
  defp assign_capabilities(socket) do
    assign(socket,
      can_orders?: Authz.can?(socket, :manage_orders),
      can_invoices?: Authz.can?(socket, :manage_invoices),
      can_subscriptions?: Authz.can?(socket, :manage_subscriptions),
      can_settings?: Authz.can?(socket, :manage_settings)
    )
  end

  defp load_dashboard_data(socket) do
    %{can_orders?: orders?, can_invoices?: invoices?} = socket.assigns

    stats = if orders? or invoices?, do: Billing.get_dashboard_stats(), else: nil

    recent_orders =
      if orders?,
        do: Billing.list_orders(limit: 5, sort_by: :inserted_at, sort_order: :desc),
        else: []

    recent_invoices =
      if invoices?,
        do: Billing.list_invoices(limit: 5, sort_by: :inserted_at, sort_order: :desc),
        else: []

    currencies =
      if socket.assigns.can_settings?, do: Billing.list_currencies(enabled: true), else: []

    socket
    |> assign(:stats, stats)
    |> assign(:recent_orders, recent_orders)
    |> assign(:recent_invoices, recent_invoices)
    |> assign(:currencies, currencies)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  @impl true
  def handle_event("view_order", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Paths.order_detail(uuid))}
  end

  @impl true
  def handle_event("view_invoice", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Paths.invoice_detail(uuid))}
  end
end
