defmodule PhoenixKitBilling.CurrenciesBaseRateTest do
  @moduledoc """
  Pins the base-rate invariant from the currency design spec (§3.2):
  `set_default_currency/1` renormalizes every rate so the promoted
  currency reads exactly `1.0`, past the changeset (no validation of
  "base = 1.0" is added to `Currency.changeset/2` — see the moduledoc
  note at the call site).
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency

  defp seed do
    Repo.delete_all(Currency)

    {:ok, eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        exchange_rate: "1.10"
      })

    {:ok, gbp} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        enabled: false,
        exchange_rate: "0.85"
      })

    %{eur: eur, usd: usd, gbp: gbp}
  end

  test "promoting a currency renormalizes every rate so the new base is exactly 1.0 (§3.2)" do
    %{usd: usd} = seed()

    assert {:ok, %Currency{code: "USD", is_default: true, exchange_rate: rate}} =
             PhoenixKitBilling.set_default_currency(usd)

    assert Decimal.equal?(rate, Decimal.new("1.0"))

    by_code = Map.new(PhoenixKitBilling.list_currencies(), &{&1.code, &1})
    assert Decimal.equal?(by_code["EUR"].exchange_rate, Decimal.new("0.909091"))
    assert Decimal.equal?(by_code["GBP"].exchange_rate, Decimal.new("0.772727"))
    refute by_code["EUR"].is_default
    # GBP stays disabled — promotion touches `enabled` of the promoted row only
    refute by_code["GBP"].enabled
  end

  test "promotion keeps every conversion ratio (numbers on screen do not move)" do
    %{usd: usd, eur: eur, gbp: gbp} = seed()
    before = Currency.convert(Decimal.new("19.99"), usd, gbp)
    {:ok, _} = PhoenixKitBilling.set_default_currency(usd)
    usd2 = PhoenixKitBilling.get_currency_by_code("USD")
    gbp2 = PhoenixKitBilling.get_currency_by_code("GBP")
    assert Decimal.equal?(before, Currency.convert(Decimal.new("19.99"), usd2, gbp2))

    assert Decimal.equal?(
             Currency.convert(
               Decimal.new("19.99"),
               usd2,
               PhoenixKitBilling.get_currency_by_code("EUR")
             ),
             Decimal.new("18.17")
           )

    _ = eur
  end

  test "a base with a non-positive rate is refused instead of dividing by zero" do
    %{usd: usd} = seed()

    Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == "USD"),
      set: [exchange_rate: Decimal.new("0")]
    )

    usd = %{usd | exchange_rate: Decimal.new("0")}
    assert {:error, :invalid_base_rate} = PhoenixKitBilling.set_default_currency(usd)
  end

  test "re-promoting the current default keeps it default and pins its rate to 1.0" do
    Repo.delete_all(Currency)

    {:ok, usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.10"
      })

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "1.0"
      })

    {:ok, _gbp} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        enabled: false,
        exchange_rate: "0.85"
      })

    # `usd` is ALREADY the default here — the struct's own `is_default`
    # field is `true` before the call, same as what
    # `PhoenixKitBilling.get_default_currency/0` would hand a caller who
    # wants to fix the current default's rate without switching currencies
    # (exactly what `mix decor.renormalize_fx_rates` does). This is the
    # regression case: re-promoting the currency that is already default
    # must not leave the table with NO default at all.
    assert {:ok, %Currency{code: "USD", is_default: true, exchange_rate: rate}} =
             PhoenixKitBilling.set_default_currency(usd)

    assert Decimal.equal?(rate, Decimal.new("1.0"))

    currencies = PhoenixKitBilling.list_currencies()
    defaults = Enum.filter(currencies, & &1.is_default)
    assert [%Currency{code: "USD"}] = defaults

    by_code = Map.new(currencies, &{&1.code, &1})
    assert Decimal.equal?(by_code["USD"].exchange_rate, Decimal.new("1.0"))
    assert Decimal.equal?(by_code["EUR"].exchange_rate, Decimal.new("0.909091"))
    assert Decimal.equal?(by_code["GBP"].exchange_rate, Decimal.new("0.772727"))
  end
end
