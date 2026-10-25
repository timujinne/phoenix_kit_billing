defmodule PhoenixKitBilling.Web.Components.TrashMark do
  @moduledoc """
  What the admin pages show of a document that is in the trash: a badge next to
  its status and, on the detail page, a notice with when and by whom.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitBilling.Gettext

  alias PhoenixKit.Users.Auth

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TimeDisplay

  @doc """
  Badge for a document in the trash.
  """
  attr(:id, :string, required: true)
  attr(:size, :atom, default: :sm, values: [:xs, :sm, :md, :lg])
  attr(:class, :string, default: "")

  def trash_badge(assigns) do
    ~H"""
    <span id={@id} class={["badge badge-warning gap-1", size_class(@size), @class]}>
      <.icon name="hero-trash" class="w-3 h-3" /> {gettext("In trash")}
    </span>
    """
  end

  @doc """
  Notice for the top of a detail page: the document is in the trash, since when
  and by whom (`by` is the user's email, or `nil` when nobody is named).
  """
  attr(:id, :string, required: true)
  attr(:trashed_at, :any, required: true)
  attr(:by, :string, default: nil)

  def trash_notice(assigns) do
    ~H"""
    <div id={@id} role="alert" class="alert alert-warning alert-soft mb-6">
      <.icon name="hero-trash" class="w-6 h-6" />
      <div>
        <h3 class="font-bold uppercase">{gettext("In trash")}</h3>
        <p class="text-sm">
          {gettext("Moved to the trash")} <.time_ago datetime={@trashed_at} />
        </p>
        <p :if={@by} id={"#{@id}-by"} class="text-sm">{gettext("By %{user}", user: @by)}</p>
        <p class="text-sm">{gettext("Restore it to work with it again.")}</p>
      </div>
    </div>
    """
  end

  @doc """
  The emails of the users who trashed `records` (anything with a
  `trashed_by_uuid`), by user uuid. A user who is gone, or nobody, is absent.
  One lookup per distinct user: a page of the trash has a handful.
  """
  @spec trashed_by_emails([map()]) :: %{String.t() => String.t()}
  def trashed_by_emails(records) do
    records
    |> Enum.map(& &1.trashed_by_uuid)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn uuid -> Auth.get_user(uuid) end)
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.uuid, &1.email})
  end

  @doc """
  The email of the user who trashed `record`, or `nil`.
  """
  @spec trashed_by_email(map()) :: String.t() | nil
  def trashed_by_email(record) do
    [record] |> trashed_by_emails() |> Map.get(record.trashed_by_uuid)
  end

  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
