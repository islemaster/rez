defmodule Rez.AST.Item do
  alias __MODULE__
  alias Rez.AST.{NodeHelper, TemplateHelper, TypeHierarchy}

  @moduledoc """
  `Rez.AST.Item` defines the `Item` struct.

  An `Item` specifies some in-game artifact that the player can acquire and
  that will be part of an inventory.

  `Item`s do not necessarily have to refer to physical items. A "spell" could
  be an item that would live in an `Inventory` representing a spell book.

  Each `Item` has a category to match to a compatible `Inventory` that has
  the same category. Each `Item` also defines the slot it can sit in, within
  that `Inventory`. `Slot`s are for `Item`s that are interchangable with each
  other.
  """
  defstruct [
    status: :ok,
    id: nil,
    position: {nil, 0, 0},
    attributes: %{},
    template: nil
  ]

  # Items support a handlebars template for their 'description' attribute
  def process(%Item{} = item) do
    item
    |> set_defaults()
    |> make_template()
  end

  defp set_defaults(%Item{} = item) do
    item
    |> NodeHelper.set_default_attr_value("size", 1, &NodeHelper.set_number_attr/3)
  end

  defp make_template(%Item{id: item_id} = item) do
    TemplateHelper.make_template(
      item,
      "description",
      :template,
      fn html ->
        ~s(<div id="item_#{item_id}" class="item">) <> html <> "</div>"
      end
    )
  end

  def add_types_as_tags(%Item{} = item, %TypeHierarchy{} = is_a) do
    case NodeHelper.get_attr_value(item, "type") do
      nil ->
        item

      type ->
        tags = case NodeHelper.get_attr(item, "tags") do
          nil ->
            MapSet.new()

          %{value: value} ->
            value
        end

        expanded_types =
          [type | TypeHierarchy.fan_out(is_a, type)]
          |> Enum.map(fn type -> {:keyword, type} end)

        tags = Enum.reduce(expanded_types, tags, fn tag, tags ->
          MapSet.put(tags, tag)
        end)

        NodeHelper.set_set_attr(item, "tags", tags)
    end
  end
end

defimpl Rez.AST.Node, for: Rez.AST.Item do
  import Rez.AST.NodeValidator
  alias Rez.AST.{NodeHelper, Game, Item}
  alias Rez.AST.Node

  def node_type(_item), do: "item"

  def pre_process(item), do: item

  def process(item), do: Item.process(item)

  def children(_item), do: []

  def validators(item) do
    [
      attribute_if_present?("tags",
        attribute_is_keyword_set?()),

      attribute_if_present?("description",
        attribute_has_type?(:string)),

      attribute_present?("type",
        attribute_has_type?(:keyword)),

      attribute_if_present?("container",
        attribute_has_type?(:elem_ref,
          attribute_refers_to?("inventory"))),

      attribute_if_present?("size",
        attribute_has_type?(:number,
          value_passes?(fn size -> size >= 0 end, "must not be negative"))),

      attribute_if_present?("usable",
        attribute_has_type?(:boolean)),

      attribute_if_present?("asset",
        attribute_has_type?(:elem_ref,
          attribute_refers_to?("assets"))),

      attribute_if_present?("consumable",
        attribute_has_type?(:boolean,
          validate_if_value?(true,
            other_attributes_present?(["uses"])))),

      attribute_if_present?("uses",
        attribute_has_type?(:number,
          value_passes?(fn uses -> uses >= 0 end, "must not be negative"))),

      attribute_if_present?("effects",
        attribute_has_type?(:list,
          attribute_coll_of?(:elem_ref,
            attribute_list_references?("effect")))),

      node_passes?(
        fn node, %Game{slots: slots} = game ->
          case NodeHelper.get_attr_value(item, "type") do
            nil ->
              {:error, "No 'type' attribute available for #{Node.node_type(node)}/#{node.id}"}

            type ->
              accepted_types =
                slots
                |> Enum.map(
                  fn {_slot_id, slot} -> NodeHelper.get_attr_value(slot, "accepts") end)
                # We need to filter the results because if a slot is missing its
                # accepts: attribute we'll get a nil in the results but this will
                # cause an exception before the item can finish validating and
                # validation errors can be reported
                |> Enum.filter(&!is_nil(&1))
                |> Enum.uniq()

              case Enum.any?(accepted_types, fn accepted_type -> Game.is_a(game, type, accepted_type) end) do
                true -> :ok
                false -> {:error, "No slot found accepting type #{type} for item #{item.id}"}
              end
          end
        end)
      ]
  end
end
