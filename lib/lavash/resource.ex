defmodule Lavash.Resource do
  @moduledoc """
  Ash extension for Lavash resource configuration.

  This extension allows you to configure fine-grained PubSub invalidation
  directly on your Ash resources.

  ## Usage

      defmodule MyApp.Product do
        use Ash.Resource,
          extensions: [Lavash.Resource]

        lavash do
          notify_on [:category_id, :in_stock]
        end
      end

  ## Options

  * `notify_on` - List of attributes to broadcast changes for. When a mutation
    changes any of these attributes, Lavash will broadcast to combination topics
    so that LiveViews filtering on these attributes can be notified.

  ## How it works

  When a form submits and mutates a resource with `notify_on` configured:

  1. Lavash extracts the old and new values for each `notify_on` attribute
  2. Broadcasts to all subset combinations of those attribute values
  3. LiveViews subscribed to matching combination topics receive invalidation

  This enables fine-grained cache invalidation - only LiveViews whose current
  filters match the changed record will be refreshed.
  """

  @lavash %Spark.Dsl.Section{
    name: :lavash,
    describe: "Lavash configuration for this resource",
    schema: [
      notify_on: [
        type: {:list, :atom},
        default: [],
        doc: """
        List of attributes to broadcast changes for.
        When mutations change these attributes, Lavash broadcasts to
        combination topics for fine-grained invalidation.
        """
      ]
    ]
  }

  @sections [@lavash]

  use Spark.Dsl.Extension,
    sections: @sections

  @doc """
  Returns the notify_on attributes for a resource, or empty list if not configured.
  """
  def notify_on(resource) when is_atom(resource) do
    try do
      Spark.Dsl.Extension.get_opt(resource, [:lavash], :notify_on, [])
    rescue
      _ -> []
    end
  end
end
