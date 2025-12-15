defmodule Lavash.Component.Compiler do
  @moduledoc """
  Compiles the Lavash Component DSL into LiveComponent callbacks.
  """

  defmacro __before_compile__(_env) do
    quote do
      @impl Phoenix.LiveComponent
      def update(assigns, socket) do
        Lavash.Component.Runtime.update(__MODULE__, assigns, socket)
      end

      @impl Phoenix.LiveComponent
      def handle_event(event, params, socket) do
        Lavash.Component.Runtime.handle_event(__MODULE__, event, params, socket)
      end

      # Introspection functions
      def __lavash__(:props) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:props])
      end

      def __lavash__(:socket_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :socket])
      end

      def __lavash__(:ephemeral_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :ephemeral])
      end

      def __lavash__(:derived_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derived])
      end

      def __lavash__(:actions) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
      end

      # Empty fields for LiveView-only features (components don't have these)
      def __lavash__(:url_fields), do: []
      def __lavash__(:forms), do: []
    end
  end
end
