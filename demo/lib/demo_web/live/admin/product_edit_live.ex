defmodule DemoWeb.Admin.ProductEditLive do
  use Lavash.LiveView
  use Phoenix.VerifiedRoutes, endpoint: DemoWeb.Endpoint, router: DemoWeb.Router

  alias Demo.Catalog.Product

  state :product_id, :integer, from: :url
  state :submitting, :boolean, from: :ephemeral, default: false

  read :product, Product do
    id state(:product_id)
  end

  form :form, Product do
    data result(:product)
  end

  actions do
    action :save do
      set :submitting, true
      submit :form, on_error: :save_failed
      flash :info, "Product saved successfully!"
      navigate "/admin/products"
    end

    action :save_failed do
      set :submitting, false
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <a href={~p"/admin/products"} class="btn btn-ghost btn-sm">&larr;</a>
        <h1 class="text-2xl font-bold">
          {if @form_action == :create, do: "New Product", else: "Edit Product"}
        </h1>
      </div>

      <.async_result :let={form} assign={@form}>
        <:loading>
          <div class="card bg-base-200">
            <div class="card-body">
              <div class="animate-pulse space-y-4">
                <div class="h-4 bg-base-300 rounded w-1/4"></div>
                <div class="h-10 bg-base-300 rounded"></div>
                <div class="h-4 bg-base-300 rounded w-1/4"></div>
                <div class="h-10 bg-base-300 rounded"></div>
              </div>
            </div>
          </div>
        </:loading>
        <:failed :let={_reason}>
          <div class="card bg-base-200">
            <div class="card-body text-center">
              <p class="text-base-content/50">Product not found</p>
              <a href={~p"/admin/products"} class="btn btn-ghost mt-4">Back to Products</a>
            </div>
          </div>
        </:failed>

        <div class="card bg-base-200">
          <div class="card-body">
            <.form for={form} phx-change="validate" phx-submit="save" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  type="text"
                  name={form[:name].name}
                  value={form[:name].value}
                  class={["input input-bordered", form[:name].errors != [] && "input-error"]}
                />
                <.field_errors errors={form[:name].errors} />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Category</span></label>
                <input
                  type="text"
                  name={form[:category].name}
                  value={form[:category].value}
                  class={["input input-bordered", form[:category].errors != [] && "input-error"]}
                />
                <.field_errors errors={form[:category].errors} />
              </div>

              <div class="grid grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label"><span class="label-text">Price</span></label>
                  <input
                    type="number"
                    step="0.01"
                    name={form[:price].name}
                    value={form[:price].value}
                    class={["input input-bordered", form[:price].errors != [] && "input-error"]}
                  />
                  <.field_errors errors={form[:price].errors} />
                </div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Rating</span></label>
                  <input
                    type="number"
                    step="0.1"
                    min="0"
                    max="5"
                    name={form[:rating].name}
                    value={form[:rating].value}
                    class="input input-bordered"
                  />
                </div>
              </div>

              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-4">
                  <input
                    type="checkbox"
                    name={form[:in_stock].name}
                    value="true"
                    checked={form[:in_stock].value == true}
                    class="checkbox"
                  />
                  <span class="label-text">In Stock</span>
                </label>
              </div>

              <div class="flex gap-4 pt-4">
                <button type="submit" disabled={@submitting} class="btn btn-primary">
                  {cond do
                    @submitting -> "Saving..."
                    @form_action == :create -> "Create Product"
                    true -> "Save Changes"
                  end}
                </button>
                <a href={~p"/admin/products"} class="btn btn-ghost">Cancel</a>
              </div>
            </.form>
          </div>
        </div>
      </.async_result>
    </div>
    """
  end

  defp field_errors(assigns) do
    ~H"""
    <label :for={error <- @errors} class="label">
      <span class="label-text-alt text-error">{translate_error(error)}</span>
    </label>
    """
  end

  defp translate_error({msg, opts}) when is_list(opts) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp translate_error({msg, _opts}), do: to_string(msg)
  defp translate_error(msg) when is_binary(msg), do: msg
end
