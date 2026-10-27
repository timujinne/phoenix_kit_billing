defmodule PhoenixKitBilling.Web.BillingProfileForm do
  @moduledoc """
  Billing profile form LiveView for creating and editing billing profiles.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitBilling.Web.Components.BillingProfileFields, only: [billing_profile_fields: 1]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.Web.Trail

  @impl true
  def mount(params, session, socket) do
    # No tab names this page, so core's route gate admits any "billing"
    # holder; the page itself checks the capability its records need.
    Authz.authorize_mount(socket, :manage_orders, fn -> do_mount(params, session, socket) end)
  end

  defp do_mount(_params, _session, socket) do
    if Billing.enabled?() do
      # Per phoenix-thinking iron law: defer DB reads to handle_params.
      {:ok,
       socket
       |> assign(:project_title, nil)
       |> assign(:users, [])
       |> assign(:countries, [])
       |> assign(:profile_type, "individual")
       |> assign(:profile, nil)
       |> assign(:form, nil)
       |> assign(:selected_user_uuid, nil)
       |> assign(:subdivision_label, gettext("Region"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  defp load_profile(socket, nil) do
    # New profile
    changeset = Billing.change_billing_profile(%BillingProfile{type: "individual"})

    socket
    |> Trail.billing(gettext("New billing profile"), [Trail.billing_profiles()])
    |> assign(:profile, nil)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_user_uuid, nil)
    |> assign(:subdivision_label, gettext("Region"))
  end

  defp load_profile(socket, id) do
    case Billing.get_billing_profile(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Billing profile not found"))
        |> push_navigate(to: Routes.path("/admin/billing/profiles"))

      profile ->
        changeset = Billing.change_billing_profile(profile)

        socket
        |> Trail.billing(gettext("Edit"), [
          Trail.billing_profiles(),
          Trail.crumb(profile_name(profile))
        ])
        |> assign(:profile, profile)
        |> assign(:form, to_form(changeset))
        |> assign(:selected_user_uuid, profile.user_uuid)
        |> assign(:profile_type, profile.type)
        |> assign(:subdivision_label, CountryData.get_subdivision_label(profile.country))
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    project_title = Settings.get_project_title()
    %{users: users} = Auth.list_users_paginated(limit: 100)
    countries = CountryData.countries_for_select()

    socket =
      socket
      |> assign(:project_title, project_title)
      |> assign(:users, users)
      |> assign(:countries, countries)
      |> load_profile(params["id"])

    {:noreply, socket}
  end

  # A profile has no page of its own, so on the edit page its crumb is text:
  # the company, or the person, the profile belongs to.
  defp profile_name(%{type: "company", company_name: name}) when is_binary(name) and name != "",
    do: name

  defp profile_name(profile),
    do: String.trim("#{profile.first_name} #{profile.last_name}")

  @impl true
  def handle_event("select_user", %{"user_uuid" => user_uuid}, socket) do
    user_uuid = if user_uuid == "", do: nil, else: user_uuid
    {:noreply, assign(socket, :selected_user_uuid, user_uuid)}
  end

  @impl true
  def handle_event("change_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :profile_type, type)}
  end

  @impl true
  def handle_event("validate", %{"billing_profile" => params}, socket) do
    changeset =
      (socket.assigns.profile || %BillingProfile{})
      |> Billing.change_billing_profile(params)
      |> Map.put(:action, :validate)

    # Update subdivision label when country changes
    subdivision_label = CountryData.get_subdivision_label(params["country"])

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:subdivision_label, subdivision_label)}
  end

  @impl true
  def handle_event("save", %{"billing_profile" => params}, socket) do
    Authz.authorize(socket, :manage_orders, fn ->
      params =
        params
        |> Map.put("user_uuid", socket.assigns.selected_user_uuid)
        |> Map.put("type", socket.assigns.profile_type)

      save_profile(socket, params)
    end)
  end

  defp save_profile(socket, params) do
    result =
      if socket.assigns.profile do
        Billing.update_billing_profile(socket.assigns.profile, params)
      else
        case socket.assigns.selected_user_uuid do
          nil ->
            {:error, :no_user}

          user_uuid ->
            Billing.create_billing_profile(user_uuid, params)
        end
      end

    case result do
      {:ok, profile} ->
        action =
          if socket.assigns.profile,
            do: "billing.billing_profile_updated",
            else: "billing.billing_profile_created"

        Activity.log(action,
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "billing_profile",
          resource_uuid: profile.uuid,
          metadata: %{
            "type" => profile.type,
            "country" => profile.country,
            "is_default" => profile.is_default
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Billing profile saved successfully"))
         |> push_navigate(to: Routes.path("/admin/billing/profiles"))}

      {:error, :no_user} ->
        {:noreply, put_flash(socket, :error, gettext("Please select a user"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
