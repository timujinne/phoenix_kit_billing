defmodule PhoenixKitBilling.Web.Orders do
  @moduledoc """
  Orders list LiveView for the billing module.

  Provides order management interface with filtering, searching, and pagination.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.UserInfo
  alias PhoenixKit.Utils.Routes
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Pagination
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.TimeDisplay
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.OrderStatusBadge

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Web.Trail

  @default_per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      # Subscribe to order events for real-time updates
      if connected?(socket), do: Events.subscribe_orders()

      project_title = Settings.get_project_title()

      socket =
        socket
        |> Trail.billing(gettext("Orders"))
        |> assign(:project_title, project_title)
        |> assign(:orders, [])
        |> assign(:total_count, 0)
        |> assign(:loading, true)
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_orders()

    {:noreply, socket}
  end

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:search, "")
    |> assign(:status_filter, "all")
    |> assign(:date_from, nil)
    |> assign(:date_to, nil)
  end

  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:total_pages, 1)
  end

  defp apply_params(socket, params) do
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])
    search = params["search"] || ""
    status = params["status"] || "all"

    socket
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:search, search)
    |> assign(:status_filter, status)
  end

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: max(1, String.to_integer(page))
  defp parse_page(page) when is_integer(page), do: max(1, page)

  defp parse_per_page(nil), do: @default_per_page

  defp parse_per_page(per_page) when is_binary(per_page),
    do: min(100, max(10, String.to_integer(per_page)))

  defp parse_per_page(per_page) when is_integer(per_page), do: min(100, max(10, per_page))

  defp load_orders(socket) do
    %{
      page: page,
      per_page: per_page,
      search: search,
      status_filter: status
    } = socket.assigns

    opts = [
      page: page,
      per_page: per_page,
      search: search,
      status: if(status == "all", do: nil, else: status),
      preload: [:user]
    ]

    {orders, total_count} = Billing.list_orders_with_count(opts)
    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:orders, orders)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, max(1, total_pages))
    |> assign(:loading, false)
  end

  @impl true
  # `replace: true` because the search box is debounced: without it a
  # typed-out query leaves one history entry per pause, and Back walks the
  # search string backwards a few characters at a time instead of leaving
  # the page. Matches the subscriptions list.
  def handle_event("filter", params, socket) do
    new_params = build_url_params(socket.assigns, params)

    {:noreply,
     push_patch(socket,
       to: Routes.path("/admin/billing/orders?#{new_params}"),
       replace: true
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/orders"))}
  end

  @impl true
  def handle_event("view_order", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/orders/#{uuid}"))}
  end

  @impl true
  def handle_event("page_change", %{"page" => page}, socket) do
    new_params = build_url_params(socket.assigns, %{"page" => page})
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/orders?#{new_params}"))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_orders()}
  end

  # PubSub event handlers for real-time updates
  @impl true
  def handle_info({event, _order}, socket)
      when event in [
             :order_created,
             :order_updated,
             :order_confirmed,
             :order_paid,
             :order_refunded,
             :order_cancelled
           ] do
    {:noreply, load_orders(socket)}
  end

  # Catch-all for any other messages (ignore them)
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp build_url_params(assigns, new_params) do
    params = %{
      "page" => Map.get(new_params, "page", assigns.page),
      "per_page" => assigns.per_page,
      "search" => Map.get(new_params, "search", assigns.search),
      "status" => Map.get(new_params, "status", assigns.status_filter)
    }

    params
    |> Enum.reject(fn
      {_k, v} when v in ["", "all", nil] -> true
      {"page", 1} -> true
      {"per_page", @default_per_page} -> true
      _ -> false
    end)
    |> URI.encode_query()
  end
end
