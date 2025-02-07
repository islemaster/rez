defmodule Rez.AST.Scene do
  alias __MODULE__
  alias Rez.AST.TemplateHelper

  @moduledoc """
  `Rez.AST.Scene defines the `Scene` struct.

  A `Scene` represents a coherent piece of narrative that will be experienced
  by the player through one or more `Card`s.

  The `Scene` contains a layout that is wrapped around the content generated
  by `Card`s. For example a `Scene` might layout a storefront and use
  `Cards` to represent the process of browsing the store and buying items.

  Additionally a `Scene` can specify a `Location` to refer to objects that can
  be included or scenery that can be used to embellish.
  """
  defstruct status: :ok,
            position: {nil, 0, 0},
            id: nil,
            attributes: %{},
            message: "",
            layout_template: nil

  def compile_layout(%{status: :ok, id: scene_id} = scene) do
    TemplateHelper.make_template(
      scene,
      "layout",
      :layout_template,
      fn html ->
        ~s(<div id="scene_#{scene_id}"" class="scene">) <>
        html <>
        "</div>"
      end
    )
  end

  def compile_layout(scene) do
    scene
  end
end

defimpl Rez.AST.Node, for: Rez.AST.Scene do
  import Rez.AST.NodeValidator
  alias Rez.AST.Scene

  def node_type(_scene), do: "scene"

  def pre_process(scene), do: scene

  def process(scene), do: Scene.compile_layout(scene)

  def children(_scene), do: []

  def validators(_scene) do
    [
      attribute_if_present?("tags",
        attribute_is_keyword_set?()),

      attribute_present?("layout",
        attribute_has_type?(:string)),

      attribute_if_present?("layout_mode",
        attribute_has_type?(:keyword,
          attribute_value_is_one_of?(["single", "continuous"]))),

      attribute_if_present?("blocks",
        attribute_has_type?(:list,
          attribute_coll_of?(:elem_ref,
            attribute_list_references?("card")))),

      attribute_if_present?("location",
        attribute_has_type?(:elem_ref,
          attribute_refers_to?("location"))),

      attribute_present?("initial_card",
        attribute_has_type?(:elem_ref,
          attribute_refers_to?("card"))),

      attribute_if_present?("on_init",
        attribute_has_type?(:function)),

      attribute_if_present?("on_start",
        attribute_has_type?(:function)),

      attribute_if_present?("on_finish",
        attribute_has_type?(:function)),

      attribute_if_present?("on_interrupt",
        attribute_has_type?(:function)),

      attribute_if_present?("on_resume",
        attribute_has_type?(:function)),

      attribute_if_present?("on_render",
        attribute_has_type?(:function)),

      attribute_if_present?("on_start_card",
        attribute_has_type?(:function)),

      attribute_if_present?("on_finish_card",
        attribute_has_type?(:function))
    ]
  end
end
