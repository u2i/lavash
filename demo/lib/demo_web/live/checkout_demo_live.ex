defmodule DemoWeb.CheckoutDemoLive do
  @moduledoc """
  Shopify-style checkout demo showcasing Lavash styling capabilities.

  Demonstrates:
  - Ash `form` DSL for auto-generated validation from resource constraints
  - `data-lavash-toggle` for dynamic class switching on validation state
  - `data-lavash-enabled` for button enable/disable
  - `data-lavash-visible` for conditional section visibility
  - `data-lavash-display` for reactive text updates
  - `extend_errors` for custom validation messages beyond Ash constraints
  """
  use Lavash.LiveView
  import Lavash.Rx
  import Lavash.LiveView.Helpers, only: [field_errors: 1, field_success: 1, field_status: 1]

  alias Demo.Forms.Payment

  # ─────────────────────────────────────────────────────────────────
  # State
  # ─────────────────────────────────────────────────────────────────

  # Payment form params - Lavash automatically populates from form events
  state :payment_params, :map, from: :ephemeral, default: %{}, optimistic: true

  # UI state
  state :payment_method, :string, from: :ephemeral, default: "card", optimistic: true
  state :use_shipping_as_billing, :boolean, from: :ephemeral, default: true, optimistic: true
  state :ship_to_expanded, :boolean, from: :ephemeral, default: true, optimistic: true
  state :submitted, :boolean, from: :ephemeral, default: false, optimistic: true

  # Order data (would come from cart in real app)
  state :subtotal, :decimal, from: :ephemeral, default: Decimal.new("20.00"), optimistic: false
  state :shipping, :decimal, from: :ephemeral, default: Decimal.new("8.00"), optimistic: false

  # ─────────────────────────────────────────────────────────────────
  # Ash Form - Auto-generates validation from Payment resource
  # ─────────────────────────────────────────────────────────────────

  # Auto-generates: payment_card_number_valid, payment_card_number_errors, etc.
  form :payment, Payment do
    create :pay
  end

  # ─────────────────────────────────────────────────────────────────
  # Card Type Detection (for badge highlighting and Amex-specific rules)
  # ─────────────────────────────────────────────────────────────────

  calculate :card_number_raw, rx(@payment_params["card_number"] || "")
  calculate :card_number_digits, rx(String.replace(@card_number_raw, ~r/\D/, ""))
  calculate :card_number_length, rx(String.length(@card_number_digits))

  # Detect card type from first digit(s)
  calculate :card_starts_with_4, rx(String.starts_with?(@card_number_digits, "4"))
  calculate :card_starts_with_5, rx(String.starts_with?(@card_number_digits, "5"))
  calculate :card_starts_with_34, rx(String.starts_with?(@card_number_digits, "34"))
  calculate :card_starts_with_37, rx(String.starts_with?(@card_number_digits, "37"))
  calculate :card_starts_with_6011, rx(String.starts_with?(@card_number_digits, "6011"))

  calculate :is_visa, rx(@card_starts_with_4)
  calculate :is_mastercard, rx(@card_starts_with_5)
  calculate :is_amex, rx(@card_starts_with_34 or @card_starts_with_37)
  calculate :is_discover, rx(@card_starts_with_6011)

  # Card type display for badges - highlight detected type, dim others
  calculate :has_card_type, rx(@is_visa or @is_mastercard or @is_amex or @is_discover)
  calculate :show_visa, rx(@is_visa or not @has_card_type)
  calculate :show_mastercard, rx(@is_mastercard or not @has_card_type)
  calculate :show_amex, rx(@is_amex or not @has_card_type)
  calculate :show_discover, rx(@is_discover or not @has_card_type)

  # ─────────────────────────────────────────────────────────────────
  # Extended Validation - Custom errors beyond Ash constraints
  # ─────────────────────────────────────────────────────────────────

  # Expiration date: validate month is 01-12
  calculate :expiry_raw, rx(@payment_params["expiry"] || "")
  calculate :expiry_digits, rx(String.replace(@expiry_raw, ~r/\D/, ""))
  calculate :expiry_month_str, rx(String.slice(@expiry_digits, 0, 2))
  calculate :expiry_has_month, rx(String.length(@expiry_month_str) == 2)
  calculate :expiry_month_int, rx(if(@expiry_has_month, do: String.to_integer(@expiry_month_str), else: 0))
  calculate :expiry_month_valid, rx(@expiry_month_int >= 1 and @expiry_month_int <= 12)

  extend_errors :payment_expiry_errors do
    error rx(@expiry_month_valid == false and String.length(@expiry_digits) >= 2), "Month must be 01-12"
  end

  # CVV: 4 digits for Amex, 3 for others
  calculate :cvv_raw, rx(@payment_params["cvv"] || "")
  calculate :cvv_length, rx(String.length(String.replace(@cvv_raw, ~r/\D/, "")))
  calculate :cvv_valid_for_card_type, rx(if(@is_amex, do: @cvv_length == 4, else: @cvv_length == 3))

  # CVV: dynamic error message based on card type
  # Use @cvv_valid_for_card_type == false (not `not`) to handle nil gracefully
  extend_errors :payment_cvv_errors do
    error rx(@cvv_valid_for_card_type == false and @cvv_length > 0),
      rx(if(@is_amex, do: "Amex requires 4 digits", else: "Must be 3 digits"))
  end

  # Card number: 15 digits for Amex, 16 for others
  calculate :card_valid_for_type, rx(if(@is_amex, do: @card_number_length == 15, else: @card_number_length == 16))

  # Card number: dynamic error message based on card type
  extend_errors :payment_card_number_errors do
    error rx(@card_valid_for_type == false and @card_number_length > 0),
      rx(if(@is_amex, do: "Amex requires 15 digits", else: "Must be 16 digits"))
  end

  # Override validity to include card-type-specific rules
  calculate :card_number_valid, rx(@payment_card_number_valid and @card_valid_for_type)
  calculate :expiry_valid, rx(@payment_expiry_valid and @expiry_month_valid)
  calculate :cvv_valid, rx(@payment_cvv_valid and @cvv_valid_for_card_type)

  # ─────────────────────────────────────────────────────────────────
  # Combined Form Validity
  # ─────────────────────────────────────────────────────────────────

  calculate :card_form_valid, rx(@card_number_valid and @expiry_valid and @cvv_valid and @payment_name_valid)
  calculate :is_card_payment, rx(@payment_method == "card")
  calculate :form_valid, rx(if(@is_card_payment, do: @card_form_valid, else: true))

  # ─────────────────────────────────────────────────────────────────
  # Computed Values
  # ─────────────────────────────────────────────────────────────────

  calculate :total, rx(Decimal.add(@subtotal, @shipping))
  calculate :total_display, rx("$" <> Decimal.to_string(@total))
  calculate :subtotal_display, rx("$" <> Decimal.to_string(@subtotal))
  calculate :shipping_display, rx("$" <> Decimal.to_string(@shipping))

  # ─────────────────────────────────────────────────────────────────
  # Actions
  # ─────────────────────────────────────────────────────────────────

  actions do
    action :select_card do
      set :payment_method, "card"
    end

    action :select_paypal do
      set :payment_method, "paypal"
    end

    action :toggle_billing_address do
      update :use_shipping_as_billing, &(not &1)
    end

    action :toggle_ship_to do
      update :ship_to_expanded, &(not &1)
    end

    action :save do
      submit :payment, on_success: :on_saved, on_error: :on_error
    end

    action :on_saved do
      set :submitted, true
    end

    action :on_error do
      # Form errors will be displayed via Ash form
    end

    action :reset do
      set :payment_params, %{}
      set :submitted, false
      set :payment_method, "card"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Template
  # ─────────────────────────────────────────────────────────────────

  template """
  <div id="checkout-demo" data-theme="shopify" class="bg-base-200 min-h-screen">
    <main class="mx-auto max-w-6xl p-4 lg:p-8">
      <%= if @submitted do %>
        <div class="card border border-base-300 bg-base-100 shadow-sm max-w-lg mx-auto">
          <div class="card-body text-center">
            <div class="text-6xl mb-4 text-success">✓</div>
            <h2 class="text-2xl font-bold mb-2">Payment Complete!</h2>
            <p class="text-base-content/70 mb-4">Thank you for your order.</p>
            <div class="bg-base-200 rounded-xl p-4 mb-4">
              <div class="flex justify-between mb-2">
                <span>Subtotal</span>
                <span>{@subtotal_display}</span>
              </div>
              <div class="flex justify-between mb-2">
                <span>Shipping</span>
                <span>{@shipping_display}</span>
              </div>
              <div class="divider my-2"></div>
              <div class="flex justify-between font-bold text-lg">
                <span>Total</span>
                <span data-lavash-display="total_display">{@total_display}</span>
              </div>
            </div>
            <button phx-click="reset" class="btn btn-primary">Start Over</button>
          </div>
        </div>
      <% else %>
        <div class="grid grid-cols-1 gap-6 lg:grid-cols-[1.6fr_1fr]">
          <!-- LEFT COLUMN -->
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body gap-6">
              <!-- Payment method buttons -->
              <div class="flex flex-col gap-3">
                <div class="join w-full">
                  <button class="btn join-item btn-primary w-1/3 font-bold">shop</button>
                  <button class="btn join-item w-1/3 bg-yellow-400 text-slate-900 border-yellow-400 font-bold hover:bg-yellow-500">
                    PayPal
                  </button>
                  <button class="btn join-item btn-info w-1/3 font-bold text-white">venmo</button>
                </div>

                <div class="divider text-xs font-semibold text-base-content/50 uppercase">OR</div>

                <!-- Signed-in row -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-3">
                    <div class="avatar placeholder">
                      <div class="w-9 rounded-full bg-base-200 text-base-content">
                        <span class="text-sm font-bold">T</span>
                      </div>
                    </div>
                    <div class="text-sm font-semibold text-base-content/70">tom.clarke@gmail.com</div>
                  </div>
                  <button class="btn btn-ghost btn-sm" aria-label="More">⋮</button>
                </div>
              </div>

              <!-- Ship to -->
              <div class="space-y-3">
                <div class="flex items-center justify-between">
                  <div class="text-sm font-semibold">Ship to</div>
                  <button
                    phx-click="toggle_ship_to"
                    class="btn btn-ghost btn-sm"
                    aria-label="Toggle"
                  >
                    <span data-lavash-visible="ship_to_expanded" class={unless @ship_to_expanded, do: "hidden"}>▴</span>
                    <span data-lavash-visible="ship_to_expanded" data-lavash-toggle="ship_to_expanded|hidden|" class={if @ship_to_expanded, do: "hidden"}>▾</span>
                  </button>
                </div>

                <div
                  data-lavash-visible="ship_to_expanded"
                  class={"flex items-start justify-between rounded-lg border border-base-300 bg-base-200/40 p-4" <> unless @ship_to_expanded, do: " hidden", else: ""}
                >
                  <div>
                    <div class="font-semibold">Thomas Clarke, 78 Example Street</div>
                    <div class="text-sm opacity-70">Red Hook, NY 12571, US</div>
                  </div>
                  <button class="btn btn-ghost btn-sm" aria-label="Edit address">⋮</button>
                </div>

                <a class="link link-primary inline-flex items-center gap-2 text-sm font-semibold" href="#">
                  <span class="text-lg leading-none">＋</span>
                  Use a different address
                </a>
              </div>

              <!-- Shipping method -->
              <div class="space-y-3">
                <div class="flex items-center justify-between">
                  <div class="text-sm font-semibold">Shipping method</div>
                  <button class="btn btn-ghost btn-sm" aria-label="Collapse">▾</button>
                </div>

                <div class="flex items-center justify-between border-t border-base-300 pt-3">
                  <div class="text-sm font-semibold">Light Shipping</div>
                  <div class="text-sm font-semibold" data-lavash-display="shipping_display">{@shipping_display}</div>
                </div>
              </div>

              <!-- Payment -->
              <div class="space-y-4 border-t border-base-300 pt-6">
                <div>
                  <div class="text-2xl font-bold">Payment</div>
                  <div class="text-sm opacity-70">All transactions are secure and encrypted.</div>
                </div>

                <!-- Credit Card Option -->
                <div
                  class="rounded-lg border border-base-300 p-4 cursor-pointer transition-all"
                  data-lavash-toggle="is_card_payment|border-primary ring-1 ring-primary|border-base-300"
                >
                  <div class="flex items-center gap-3 cursor-pointer" phx-click="select_card">
                    <input
                      type="radio"
                      name="payment_method"
                      class="radio radio-primary"
                      checked={@payment_method == "card"}
                    />
                    <span class="font-semibold">Credit card</span>
                    <span class="ml-auto flex items-center gap-1">
                      <span
                        class="badge badge-outline badge-sm transition-opacity"
                        data-lavash-toggle="show_visa|opacity-100|opacity-30"
                      >VISA</span>
                      <span
                        class="badge badge-outline badge-sm transition-opacity"
                        data-lavash-toggle="show_mastercard|opacity-100|opacity-30"
                      >MC</span>
                      <span
                        class="badge badge-outline badge-sm transition-opacity"
                        data-lavash-toggle="show_amex|opacity-100|opacity-30"
                      >AMEX</span>
                      <span
                        class="badge badge-outline badge-sm transition-opacity"
                        data-lavash-toggle="show_discover|opacity-100|opacity-30"
                      >DISC</span>
                    </span>
                  </div>

                  <!-- Card form fields - only visible when card is selected -->
                  <.form
                    for={@payment}
                    phx-submit="save"
                    data-lavash-visible="is_card_payment"
                    class={"mt-4 space-y-3" <> if @payment_method != "card", do: " hidden", else: ""}
                  >
                    <!-- Card Number -->
                    <div>
                      <label class="floating-label w-full">
                        <input
                          type="text"
                          name={@payment[:card_number].name}
                          value={@payment[:card_number].value || ""}
                          data-lavash-bind="payment_params.card_number"
                          data-lavash-form="payment"
                          data-lavash-field="card_number"
                          data-lavash-valid="card_number_valid"
                          autocomplete="cc-number"
                          inputmode="numeric"
                          placeholder="Card number"
                          class={"input input-bordered w-full " <>
                            cond do
                              !assigns[:payment_card_number_show_errors] -> ""
                              @card_number_valid -> "input-success"
                              true -> "input-error"
                            end}
                        />
                        <span>Card number</span>
                      </label>
                      <div class="h-5 mt-1">
                        <.field_errors form={:payment} field={:card_number} errors={@payment_card_number_errors} />
                        <.field_success form={:payment} field={:card_number} valid={@card_number_valid} valid_field="card_number_valid" />
                      </div>
                    </div>

                    <div class="grid grid-cols-2 gap-3">
                      <!-- Expiration -->
                      <div>
                        <label class="floating-label w-full">
                          <input
                            type="text"
                            name={@payment[:expiry].name}
                            value={@payment[:expiry].value || ""}
                            data-lavash-bind="payment_params.expiry"
                            data-lavash-form="payment"
                            data-lavash-field="expiry"
                            data-lavash-valid="expiry_valid"
                            autocomplete="cc-exp"
                            inputmode="numeric"
                            placeholder="MM/YY"
                            maxlength="5"
                            class={"input input-bordered w-full " <>
                              cond do
                                !assigns[:payment_expiry_show_errors] -> ""
                                @expiry_valid -> "input-success"
                                true -> "input-error"
                              end}
                          />
                          <span>Expiration (MM/YY)</span>
                        </label>
                        <div class="h-5 mt-1">
                          <.field_errors form={:payment} field={:expiry} errors={@payment_expiry_errors} />
                          <.field_success form={:payment} field={:expiry} valid={@expiry_valid} valid_field="expiry_valid" />
                        </div>
                      </div>

                      <!-- CVV -->
                      <div>
                        <label class="floating-label w-full">
                          <input
                            type="text"
                            name={@payment[:cvv].name}
                            value={@payment[:cvv].value || ""}
                            data-lavash-bind="payment_params.cvv"
                            data-lavash-form="payment"
                            data-lavash-field="cvv"
                            data-lavash-valid="cvv_valid"
                            autocomplete="cc-csc"
                            inputmode="numeric"
                            placeholder="CVV"
                            maxlength="4"
                            class={"input input-bordered w-full " <>
                              cond do
                                !assigns[:payment_cvv_show_errors] -> ""
                                @cvv_valid -> "input-success"
                                true -> "input-error"
                              end}
                          />
                          <span>Security code</span>
                        </label>
                        <div class="h-5 mt-1">
                          <.field_errors form={:payment} field={:cvv} errors={@payment_cvv_errors} />
                          <.field_success form={:payment} field={:cvv} valid={@cvv_valid} valid_field="cvv_valid" />
                        </div>
                      </div>
                    </div>

                    <!-- Name on card -->
                    <div>
                      <label class="floating-label w-full">
                        <input
                          type="text"
                          name={@payment[:name].name}
                          value={@payment[:name].value || ""}
                          data-lavash-bind="payment_params.name"
                          data-lavash-form="payment"
                          data-lavash-field="name"
                          autocomplete="cc-name"
                          placeholder="Name on card"
                          class={"input input-bordered w-full " <>
                            cond do
                              !assigns[:payment_name_show_errors] -> ""
                              @payment_name_valid -> "input-success"
                              true -> "input-error"
                            end}
                        />
                        <span>Name on card</span>
                      </label>
                      <div class="h-5 mt-1">
                        <.field_errors form={:payment} field={:name} errors={@payment_name_errors} />
                        <.field_success form={:payment} field={:name} valid={@payment_name_valid} />
                      </div>
                    </div>

                    <!-- Use shipping as billing -->
                    <label class="flex items-center gap-3 cursor-pointer pt-1">
                      <input
                        type="checkbox"
                        class="checkbox checkbox-sm"
                        checked={@use_shipping_as_billing}
                        phx-click="toggle_billing_address"
                      />
                      <span class="text-sm">Use shipping address as billing address</span>
                    </label>

                    <!-- Pay Button (inside form for submit) -->
                    <button
                      type="submit"
                      disabled={not @form_valid}
                      data-lavash-enabled="form_valid"
                      class={"btn btn-lg w-full " <>
                        if @form_valid do
                          "btn-primary"
                        else
                          "btn-disabled opacity-50 cursor-not-allowed"
                        end}
                      data-lavash-toggle="form_valid|btn-primary|btn-disabled opacity-50 cursor-not-allowed"
                    >
                      Pay now
                    </button>
                  </.form>
                </div>

                <!-- PayPal Option -->
                <div
                  class="flex items-center gap-3 rounded-lg border p-4 cursor-pointer transition-all"
                  phx-click="select_paypal"
                  data-lavash-toggle="is_card_payment|border-base-300|border-primary ring-1 ring-primary"
                >
                  <input
                    type="radio"
                    name="payment_method"
                    class="radio radio-primary"
                    checked={@payment_method == "paypal"}
                  />
                  <span class="font-semibold">PayPal</span>
                  <span class="ml-auto text-sm font-bold">
                    <span class="text-[#003087]">Pay</span><span class="text-[#009cde]">Pal</span>
                  </span>
                </div>

                <!-- Pay Button for PayPal (outside form) -->
                <%= if @payment_method == "paypal" do %>
                  <button
                    phx-click="on_saved"
                    class="btn btn-lg w-full btn-primary"
                  >
                    Pay with PayPal
                  </button>
                <% end %>
              </div>
            </div>
          </section>

          <!-- RIGHT COLUMN - Order Summary -->
          <aside class="lg:sticky lg:top-5 self-start">
            <section class="card border border-base-300 bg-base-100 shadow-sm">
              <div class="card-body gap-5">
                <!-- Item -->
                <div class="flex items-start gap-4">
                  <div class="relative">
                    <div class="avatar">
                      <div class="w-14 rounded-lg bg-base-200">
                        <svg viewBox="0 0 24 24" class="h-full w-full p-3 opacity-60" fill="none">
                          <path
                            d="M7 7h10v14H7V7Z"
                            stroke="currentColor"
                            stroke-width="1.5"
                            stroke-linejoin="round"
                          />
                          <path
                            d="M9 7V5h6v2"
                            stroke="currentColor"
                            stroke-width="1.5"
                            stroke-linecap="round"
                          />
                        </svg>
                      </div>
                    </div>
                    <div class="badge badge-neutral badge-sm absolute -right-2 -top-2">1</div>
                  </div>

                  <div class="flex-1">
                    <div class="font-bold">Bali Blue Moon</div>
                    <div class="text-sm opacity-70">12 oz</div>
                  </div>

                  <div class="text-sm font-bold" data-lavash-display="subtotal_display">{@subtotal_display}</div>
                </div>

                <!-- Gift card - Floating Label -->
                <div class="flex gap-3">
                  <label class="floating-label flex-1">
                    <input type="text" placeholder="Gift card or discount code" class="input input-bordered w-full" />
                    <span>Gift card or discount code</span>
                  </label>
                  <button class="btn btn-outline">Apply</button>
                </div>

                <!-- Totals -->
                <div class="space-y-2">
                  <div class="flex items-center justify-between">
                    <span class="opacity-80">Subtotal</span>
                    <span data-lavash-display="subtotal_display">{@subtotal_display}</span>
                  </div>
                  <div class="flex items-center justify-between">
                    <span class="opacity-80">Shipping</span>
                    <span data-lavash-display="shipping_display">{@shipping_display}</span>
                  </div>

                  <div class="divider my-2"></div>

                  <div class="flex items-end justify-between">
                    <div class="text-lg font-bold">Total</div>
                    <div class="flex items-baseline gap-2">
                      <div class="text-xs opacity-60">USD</div>
                      <div class="text-2xl font-bold" data-lavash-display="total_display">{@total_display}</div>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <!-- How it works -->
            <div class="mt-4 p-4 bg-base-100 rounded-lg border border-base-300">
              <h3 class="font-semibold text-base-content mb-2">Lavash Features</h3>
              <ul class="text-sm text-base-content/70 space-y-1">
                <li>• Ash <code class="bg-base-200 px-1 rounded text-xs">form</code> DSL for validation</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">extend_errors</code> for custom messages</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">data-lavash-toggle</code> class switching</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">data-lavash-visible</code> show/hide</li>
                <li>• <code class="bg-base-200 px-1 rounded text-xs">data-lavash-enabled</code> button state</li>
                <li>• Card type detection via <code class="bg-base-200 px-1 rounded text-xs">rx()</code></li>
              </ul>
            </div>

            <div class="mt-4 text-center">
              <a href="/" class="text-primary hover:text-primary/80 text-sm">
                &larr; Back to Demos
              </a>
            </div>
          </aside>
        </div>
      <% end %>
    </main>
  </div>
  """
end
