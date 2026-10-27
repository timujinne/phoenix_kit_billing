defmodule PhoenixKitBilling.Web.SettingsDocumentsTest do
  @moduledoc """
  Billing → Settings → Printed documents: the logo and the footer text the
  printable documents and the financial emails carry.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.DocumentBranding

  @path "/en/admin/settings/billing"

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "shows the saved footer text", %{conn: conn} do
    Settings.update_setting(DocumentBranding.footer_key(), "About us")

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(
             view,
             "#billing-documents-form textarea[name=document_footer]",
             "About us"
           )
  end

  test "saves the footer text and the logo picked from the media library", %{conn: conn} do
    uuid = UUIDv7.generate()
    {:ok, view, _html} = live(conn, @path)

    view |> element("#billing-document-logo-select") |> render_click()
    send(view.pid, {:media_selected, [uuid]})

    view
    |> form("#billing-documents-form", %{"document_footer" => "  Acme — tools for home.\n"})
    |> render_submit()

    assert Settings.get_setting(DocumentBranding.footer_key()) == "Acme — tools for home."
    assert Settings.get_setting(DocumentBranding.logo_key()) == uuid
  end

  test "removes the logo", %{conn: conn} do
    Settings.update_setting(DocumentBranding.logo_key(), UUIDv7.generate())
    {:ok, view, _html} = live(conn, @path)

    view |> element("#billing-document-logo-remove") |> render_click()
    view |> form("#billing-documents-form", %{"document_footer" => ""}) |> render_submit()

    assert Settings.get_setting(DocumentBranding.logo_key(), "") == ""
    assert has_element?(view, "#billing-document-logo-select")
  end

  test "an operator without manage_settings cannot change them", %{conn: conn} do
    scope = fake_scope(permissions: ["billing"], roles: ["Employee"])
    {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

    view
    |> form("#billing-documents-form", %{"document_footer" => "Hijacked"})
    |> render_submit()

    assert Settings.get_setting(DocumentBranding.footer_key(), "") == ""
  end

  describe "a footer longer than a setting holds" do
    test "is refused with an error, keeps the text, and saves neither it nor the logo", %{
      conn: conn
    } do
      Settings.update_setting(DocumentBranding.footer_key(), "Old footer")
      long = String.duplicate("Footer ", 160)
      uuid = UUIDv7.generate()
      {:ok, view, _html} = live(conn, @path)

      view |> element("#billing-document-logo-select") |> render_click()
      send(view.pid, {:media_selected, [uuid]})

      html =
        view
        |> form("#billing-documents-form", %{"document_footer" => long})
        |> render_submit()

      assert html =~ "The footer text is too long: at most 1000 characters."
      refute html =~ "Document settings saved"
      assert has_element?(view, "#billing-document-footer", String.trim(long))
      assert has_element?(view, "#billing-document-logo-remove")
      assert Settings.get_setting(DocumentBranding.footer_key()) == "Old footer"
      assert Settings.get_setting(DocumentBranding.logo_key(), "") == ""
    end

    test "the textarea says how long it may be", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#billing-document-footer[maxlength='1000']")
    end
  end

  describe "unsaved changes" do
    test "typed footer text survives the card's own controls and the other form", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#billing-documents-form", %{"document_footer" => "Typed, not saved"})
      |> render_change()

      view |> element("#billing-document-logo-select") |> render_click()
      send(view.pid, {:media_selected, [UUIDv7.generate()]})
      view |> element("#billing-document-logo-remove") |> render_click()

      view
      |> form("form[phx-submit=save_general]", %{
        "invoice_prefix" => "INV",
        "receipt_prefix" => "RCP",
        "invoice_due_days" => "14",
        "tax_rate" => "0"
      })
      |> render_submit()

      assert has_element?(view, "#billing-document-footer", "Typed, not saved")
      assert Settings.get_setting(DocumentBranding.footer_key(), "") == ""
    end

    test "a picked logo survives saving the general settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view |> element("#billing-document-logo-select") |> render_click()
      send(view.pid, {:media_selected, [UUIDv7.generate()]})

      view
      |> form("form[phx-submit=save_general]", %{
        "invoice_prefix" => "INV",
        "receipt_prefix" => "RCP",
        "invoice_due_days" => "14",
        "tax_rate" => "0"
      })
      |> render_submit()

      assert has_element?(view, "#billing-document-logo-remove")
    end
  end

  test "a footer that is not text does not crash the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    render_hook(view, "save_documents", %{"document_footer" => %{"x" => "y"}})

    assert Process.alive?(view.pid)
    assert Settings.get_setting(DocumentBranding.footer_key(), "") == ""
  end

  test "an operator without manage_settings cannot open the media library", %{conn: conn} do
    scope = fake_scope(permissions: ["billing"], roles: ["Employee"])
    {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

    refute view |> element("#billing-document-logo-select") |> render_click() =~ "Select Logo"
  end

  test "an operator with manage_settings opens the media library", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert view |> element("#billing-document-logo-select") |> render_click() =~ "Select Logo"
  end
end
