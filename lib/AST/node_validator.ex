defmodule Rez.AST.NodeValidator do
  @moduledoc """
  `Rez.AST.NodeValidator` defines the `Validation` struct and contains
  functions for validating child nodes and attribute presence/value and so on.
  """

  defmodule Validation do
    @moduledoc """
    `Rez.AST.NodeValidator.Validation` implements the `Validation` struct
    that is passed through the validation pipeline and which collects progress
    and errors as nodes are validated.
    """

    alias __MODULE__

    defstruct game: nil, node: nil, errors: [], validated: []

    def add_error(%Validation{errors: errors} = validation, node, error) do
      %{validation | errors: [{node, error} | errors]}
    end

    def merge(
          %Validation{errors: parent_errors, validated: parent_validated} = parent_validation,
          %Validation{errors: child_errors, validated: child_validated}
        ) do
      %{
        parent_validation
        | errors: parent_errors ++ child_errors,
          validated: parent_validated ++ child_validated
      }
    end
  end

  alias Rez.AST.Node
  alias Rez.AST.NodeHelper
  alias Rez.AST.Game
  alias Rez.AST.NodeValidator.Validation

  def validate_root(%Game{} = game) do
    validate(game, game)
  end

  def validate(node, game) do
    validate(%Validation{game: game, node: node})
  end

  def validate(%Validation{} = validation) do
    validation
    |> validate_specification()
    |> validate_children()
    |> record_validation()
  end

  def validate_specification(%Validation{game: game, node: node} = pre_validation) do
    node
    |> Node.validators()
    |> Enum.reduce(
      pre_validation,
      fn validator, validation ->
        case validator.(node, game) do
          :ok -> validation
          {:error, reason} -> Validation.add_error(validation, node, reason)
        end
      end
    )
  end

  def validate_children(%Validation{game: game, node: node} = parent_validation) do
    Enum.reduce(
      Node.children(node),
      parent_validation,
      fn child, validation ->
        Validation.merge(validation, validate(child, game))
      end
    )
  end

  def record_validation(%Validation{node: node, validated: validated} = validation) do
    %{validation | validated: [NodeHelper.description(node) | validated]}
  end

  def node_has_children?(child_key, chained_validator \\ nil) do
    fn node, game ->
      case Map.get(node, child_key) do
        nil ->
          {:error, "Does not support children for #{child_key}"}

        children ->
          case {Enum.empty?(children), chained_validator} do
            {true, _} ->
              {:error, "Has no children for #{child_key}"}

            {false, nil} ->
              :ok

            {false, validator} ->
              validator.(node, game)
          end
      end
    end
  end

  def node_passes?(validator) do
    fn node, game ->
      validator.(node, game)
    end
  end

  # The first two attribute validations establish an attribute that is the
  # target of chained validators. Chained validators receive attr, node, game
  # as arguments.

  def attribute_present?(attr_key, chained_validator \\ nil) do
    fn %{attributes: attributes} = node, game ->
      case {Map.get(attributes, attr_key), is_nil(chained_validator)} do
        {nil, _} ->
          {:error, "Missing required attribute: #{attr_key}"}

        {_attr, true} ->
          :ok

        {attr, false} ->
          chained_validator.(attr, node, game)
      end
    end
  end

  def attribute_if_present?(attr_key, chained_validator) when not is_nil(chained_validator) do
    fn %{attributes: attributes} = node, game ->
      case Map.get(attributes, attr_key) do
        nil ->
          :ok

        attr ->
          chained_validator.(attr, node, game)
      end
    end
  end

  def attribute_either?(validator_1, validator_2) do
    fn attr, node, game ->
      case validator_1.(attr, node, game) do
        :ok ->
          :ok

        {:error, error_1} ->
          case validator_2.(attr, node, game) do
            :ok ->
              :ok

            {:error, error_2} ->
              {:error, "Error: #{error_1} / #{error_2}"}
          end
      end
    end
  end

  def attribute_one_of_present?(attr_keys, exclusive)
      when is_list(attr_keys) and is_boolean(exclusive) do
    fn %{attributes: attributes}, _game ->
      count_present =
        attr_keys
        |> Enum.map(&Map.has_key?(attributes, &1))
        |> Enum.filter(&Function.identity/1)
        |> Enum.count()

      case {count_present, exclusive} do
        {0, _} ->
          {:error, "One of #{inspect(attr_keys)} is expected to be defined."}

        {1, _} ->
          :ok

        {_, false} ->
          :ok

        {_, true} ->
          {:error, "Only one of #{inspect(attr_keys)} should be defined."}
      end
    end
  end

  @doc """
    A chained validator that tests for the presence of other attributes that
    become required when the main attribute is present.

    For example if "consumable" is true it requires "uses":

    attribute_if_present?("consumable",
      other_attributes_present?("uses"))
  """
  def other_attributes_present?(required_attrs, chained_validator \\ nil) when is_list(required_attrs) do
    fn attr, %{attributes: attributes} = node, game ->
      missing = Enum.reject(required_attrs, fn attr_key ->
        Map.has_key?(attributes, attr_key)
      end)

      case {Enum.empty?(missing), is_nil(chained_validator)} do
        {true, true} ->
          :ok

        {true, false} ->
          chained_validator.(attr, node, game)

        {false, _} ->
          desc = missing |> Enum.map_join(", ", fn key -> "'" <> key <> "'" end)
          {:error,
            "Attribute '#{attr.name}' requires #{desc} to be present"}
      end
    end
  end

  def attribute_is_keyword_set?(chained_validator \\ nil) do
    attribute_has_type?(:set,
      attribute_not_empty_coll?(
        attribute_coll_of?(:keyword, chained_validator)))
  end

  def attribute_has_type?(expected_type, chained_validator \\ nil) when is_atom(expected_type) do
    fn %{name: name, type: type} = attr, node, game ->
      case {type, is_nil(chained_validator)} do
        {^expected_type, true} ->
          :ok

        {^expected_type, false} ->
          chained_validator.(attr, node, game)

        {unexpected_type, _} ->
          {:error,
           "Attribute '#{name}' expected to have type #{to_string(expected_type)}, was #{to_string(unexpected_type)}"}
      end
    end
  end

  def attribute_value_is_one_of?(values, chained_validator \\ nil) when is_list(values) do
    fn %{name: name, value: value} = attr, node, game ->
      case {Enum.member?(values, value), is_nil(chained_validator)} do
        {false, _} ->
          {:error, "Attribute '#{name}' is required to have a value from [#{inspect(values)}] but was #{value}"}

        {true, true} ->
          :ok

        {true, false} ->
          chained_validator.(attr, node, game)
      end
    end
  end

  def attribute_not_empty_coll?(chained_validator \\ nil) do
    fn %{name: name, value: lst} = attr, node, game ->
      case {Enum.empty?(lst), is_nil(chained_validator)} do
        {false, true} ->
          :ok

        {false, false} ->
          chained_validator.(attr, node, game)

        {true, _} ->
          {:error, "Attribute '#{name}' must have at least one entry!"}
      end
    end
  end

  def attribute_coll_of?(expected, chained_validator \\ nil)

  def attribute_coll_of?(expected_types, chained_validator) when is_list(expected_types) do
    fn %{name: name, value: coll} = attr, node, game ->
      unexpected_types =
        coll
        |> Enum.map(fn {type, _} -> type end)
        |> Enum.filter(fn type -> !Enum.member?(expected_types, type) end)

      case {unexpected_types, is_nil(chained_validator)} do
        {[], true} ->
          :ok

        {[], false} ->
          chained_validator.(attr, node, game)

        {types, _} ->
          wrong_types = types |> Enum.uniq() |> Enum.join(", ")
          {:error, "In collection #{name} found unexpected types (#{wrong_types}) expected one of (#{Enum.join(expected_types, ", ")})"}
      end
    end
  end

  def attribute_coll_of?(expected_type, chained_validator) do
    attribute_coll_of?([expected_type], chained_validator)
  end

  @doc """
  `attribute_list_references/4` validates that the references in the list
  refer to objects of the specified `target_class` within the `parent`.

  It assumes that the attribute has already been validated to be (1) a list,
  (2) a list of elem_refs.

  It returns `{:error, "reason"}` if an object of a different class is found
  in the list. Otherwise it returns `:ok` or, if a `chained_validator` is
  passed, the result of calling the validator on the same node.
  """
  def attribute_list_references?(element, chained_validator \\ nil) when is_binary(element) do
    fn %{name: name, value: refs} = attr, node, %Game{id_map: id_map} = game ->
      invalid_refs = Enum.reject(refs, fn {_, ref_id} ->
        match?({^element, _, _}, Map.get(id_map, ref_id))
      end)

      case {Enum.empty?(invalid_refs), is_nil(chained_validator)} do
        {true, true} ->
          :ok

        {true, false} ->
          chained_validator.(attr, node, game)

        {false, _} ->
          bad_elem_refs = Enum.map_join(invalid_refs, ", ", fn {_id, ref_id} -> "##{ref_id}" end)
          {:error,
           "Attribute '#{name}' expected to refer to a list from '#{element}' but #{bad_elem_refs} does not"}
      end
    end
  end

  def attribute_refers_to?(element, chained_validator \\ nil) when is_binary(element) do
    fn %{name: name, value: value} = attr, node, %Game{id_map: id_map} = game ->
      case {Map.get(id_map, value), is_nil(chained_validator)} do
        {nil, _} ->
          {:error, "Expected #{node.id}/#{name} to refer to a #{element} but the id '#{value}' was not found."}

        {{^element, _, _}, true} ->
          :ok

        {{^element, _, _}, false} ->
          chained_validator.(attr, node, game)

        {{other_element, _, _}, _} ->
          {:error, "Expected #{value} to map to |#{element}| but found |#{other_element}|"}

      end
    end
  end

  @doc """
  `attribute_passes?/2` is a general, catch-all, validator that passes the
  attribute to a given function to return `:ok`|`{:error, reason}` using its own
  logic.
  """
  def attribute_passes?(validator) when is_function(validator) do
    fn attr, node, game ->
      validator.(attr, node, game)
    end
  end

  def validate_if_value?(test_value, chained_validator) do
    fn %{value: value} = attr, node, game ->
      if value == test_value do
        chained_validator.(attr, node, game)
      else
        :ok
      end
    end
  end

  def value_passes?(pred, test_desc, chained_validator \\ nil) do
    fn %{name: name, value: value} = attr, node, game ->
      case {pred.(value), is_nil(chained_validator)} do
        {true, true} ->
          :ok

        {true, false} ->
          chained_validator.(attr, node, game)

        {false, _} ->
          {:error, "Attribute '#{name}': #{test_desc}"}
      end
    end
  end

  def validate_is_elem?(chained_validator \\ nil) do
    fn %{name: name, value: value} = attr, node, %{id_map: id_map} = game ->
      case {Map.has_key?(id_map, value), is_nil(chained_validator)} do
        {true, true} ->
          :ok

        {true, false} ->
          chained_validator.(attr, node, game)

        {false, _} ->
          {:error, "Attribute '#{name}' should refer to a valid id but ##{value} was not found."}
      end
    end
  end

  def validate_has_params?(count, chained_validator \\ nil) do
    fn %{name: name, value: {params, _}} = attr, node, game ->
      case {count == Enum.count(params), is_nil(chained_validator)} do
        {true, true} ->
          :ok

        {true, false} ->
          chained_validator.(attr, node, game)

        {false, _} ->
          {:error, "Attribute: '#{name}' should be a function of #{count} arguments, found #{Enum.count(params)}!"}
      end
    end
  end

  def validate_expects_params?(expected_params, chained_validator \\ nil) do
    fn %{name: name, value: {params, _}} = attr, node, game ->
      case {expected_params == params, is_nil(chained_validator)} do
        {true, true} ->
          :ok

        {true, false} ->
          chained_validator.(attr, node, game)

        {false, _} ->
          {:error, "Attribute: '#{name}' was expected to be a function with arguments: #{inspect(expected_params)}, found: #{inspect(params)}"}
      end
    end
  end

  def validate_is_btree?(chained_validator \\ nil) do
    fn %{name: name, type: type, value: value} = attr, node, game ->
      case {type, value} do
        {:btree, root_task} ->
          case {validate_task(game, root_task), is_nil(chained_validator)} do
            {:ok, true} ->
              :ok

            {:ok, false} ->
              chained_validator.(attr, node, game)

            {error, _} ->
              error
          end

        invalid_tree ->
          {:error, "Attribute: '#{name}' was expected to be a behaviour tree! Got: #{inspect(invalid_tree)}"}
      end
    end
  end

  defp validate_task(%Game{tasks: tasks} = game, {:node, task_id, options, children}) do
    case Map.get(tasks, task_id) do
      nil ->
        {:error, "Undefined behaviour #{task_id}"}

      task ->
        with :ok <- validate_child_count(task, Enum.count(children)),
              :ok <- validate_options(task, options),
              :ok <- validate_children(game, children) do
            :ok
        end
    end
  end

  defp validate_task(_game, _) do
    {:error, "expected to be a task"}
  end

  defp validate_child_count(task, child_count) do
    min_children = NodeHelper.get_attr_value(task, "min_children", -1)
    max_children = NodeHelper.get_attr_value(task, "max_children", :infinity)

    case {child_count < min_children, child_count > max_children} do
      {false, false} ->
        :ok

      {false, true} ->
        {:error, "Requires at most #{max_children} children"}

      {true, false} ->
        {:error, "Requires at least #{min_children} children"}

      {true, true} ->
        {:error, "Something impossible happened. Both too few and too many children. What gives?"}
    end
  end

  defp validate_options(task, options) do
    required_opts = NodeHelper.get_attr_value(task, "options", [])
    Enum.reduce_while(required_opts, :ok, fn {_, opt}, status ->
      case Map.has_key?(options, opt) do
        true ->
          {:cont, status}

        false ->
          {:halt, {:error, "Missing required option #{opt}"}}
      end
    end)
  end

  defp validate_children(game, children) do
    child_errors =
      children
      |> Enum.map(fn child -> validate_task(game, child) end)
      |> Enum.reject(fn result -> result == :ok end)
      |> Enum.map(fn {:error, reason} -> reason end)

    case child_errors do
      [] ->
        :ok

      errors ->
        {:error, Enum.join(errors, ", ")}
    end
  end

end
