defmodule Lens do
  use Lens.Macros

  @doc ~S"""
  A lens that always reads as an empty list

      iex> Lens.empty |> Lens.get(:anything)
      []
  """
  deflens empty do
    fn data, _fun -> {[], data} end
  end

  @doc ~S"""
  Create a lens that returns data as is

      iex> Lens.root |> Lens.get(:anything)
      :anything
  """
  deflens root do
    fn data, fun ->
      {res, updated} = fun.(data)
      {[res], updated}
    end
  end

  @doc ~S"""
  Select lens based on a matcher function

      iex> selector = fn
      ...>  {:a, _} -> Lens.at(1)
      ...>  {:b, _, _} -> Lens.at(2)
      ...> end
      iex> Lens.match(selector) |> Lens.get({:b, 2, 3})
      3
  """
  deflens match(matcher_fun) do
    fn data, fun ->
      get_and_map(matcher_fun.(data), data, fun)
    end
  end

  @doc ~S"""
  Access a value at position

      iex> Lens.at(2) |> Lens.get({:a, :b, :c})
      :c
  """
  deflens at(index) do
    fn data, fun ->
      {res, updated} = fun.(get_at_index(data, index))
      {[res], set_at_index(data, index, updated)}
    end
  end

  @doc ~S"""
  Access a value at key

      iex> Lens.key(:foo) |> Lens.get(%{foo: 1})
      1
  """
  deflens key(key) do
    fn data, fun ->
      {res, updated} = fun.(get_at_key(data, key))
      {[res], set_at_key(data, key, updated)}
    end
  end

  @doc ~S"""
  Access values at given keys

      iex> Lens.keys([:a, :c]) |> Lens.get(%{a: 1, b: 2, c: 3})
      [1, 3]
  """
  deflens keys(keys) do
    fn data, fun ->
      {res, changed} = Enum.reduce(keys, {[], data}, fn key, {results, data} ->
        {res, changed} = fun.(get_at_key(data, key))
        {[res | results], set_at_key(data, key, changed)}
      end)

      {Enum.reverse(res), changed}
    end
  end

  @doc ~S"""
  Access all items on an enumerable

      iex> Lens.all |> Lens.get([1, 2, 3])
      [1, 2, 3]
  """
  deflens all, do: filter(fn _ -> true end)

  @doc """
  Compose a pair of lens by applying the second to the result of the first

      iex> Lens.seq(Lens.key(:a), Lens.key(:b)) |> Lens.get(%{a: %{b: 3}})
      3

  Piping lenses has the exact same effect:

      iex> Lens.key(:a) |> Lens.key(:b) |> Lens.get(%{a: %{b: 3}})
      3
  """
  deflens seq(lens1, lens2) do
    fn data, fun ->
      {res, changed} = get_and_map(lens1, data, fn item ->
        get_and_map(lens2, item, fun)
      end)
      {Enum.concat(res), changed}
    end
  end

  @doc ~S"""
  Combine the composition of both lens with the first one.

      iex> Lens.seq_both(Lens.key(:a), Lens.key(:b)) |> Lens.get(%{a: %{b: :c}})
      [:c, %{b: :c}]
  """
  deflens seq_both(lens1, lens2), do: Lens.both(Lens.seq(lens1, lens2), lens1)

  @doc ~S"""
  Make a lens recursive

      iex> data = %{
      ...>    items: [
      ...>      %{v: 1, items: []},
      ...>      %{v: 2, items: [
      ...>        %{v: 3, items: []}
      ...>      ]}
      ...> ]}
      iex> lens = Lens.recur(Lens.key(:items) |> Lens.all) |> Lens.key(:v)
      iex> Lens.get(lens, data)
      [1, 2, 3]
  """
  deflens recur(lens), do: &do_recur(lens, &1, &2)

  @doc ~S"""
  Combine two lenses accessing both of them as one

      iex> Lens.both(Lens.key(:a), Lens.key(:b) |> Lens.all) |> Lens.get(%{a: 1, b: [2, 3]})
      [1, 2, 3]
  """
  deflens both(lens1, lens2) do
    fn data, fun ->
      {res1, changed1} = get_and_map(lens1, data, fun)
      {res2, changed2} = get_and_map(lens2, changed1, fun)
      {res1 ++ res2, changed2}
    end
  end

  @doc ~S"""
  Lens to access values from an enumeration for which the given predicate is true

      iex> Lens.filter(&Integer.is_odd/1) |> Lens.get([1, 2, 3, 4])
      [1, 3]
  """
  deflens filter(filter_fun) do
    fn data, fun ->
      {res, updated} = Enum.reduce(data, {[], []}, fn item, {res, updated} ->
        if filter_fun.(item) do
          {res_item, updated_item} = fun.(item)
          {[res_item | res], [updated_item | updated]}
        else
          {res, [item | updated]}
        end
      end)
      {Enum.reverse(res), Enum.reverse(updated)}
    end
  end

  @doc ~S"""
  Access values from a previous lens that satisfy the given predicate

      iex> Lens.both(Lens.key(:a), Lens.key(:b)) |> Lens.satisfy(&Integer.is_odd/1) |> Lens.get(%{a: 1, b: 2})
      1
  """
  deflens satisfy(lens, filter_fun) do
    fn data, fun ->
      {res, changed} = get_and_map(lens, data, fn item ->
        if filter_fun.(item) do
          {res, changed} = fun.(item)
          {[res], changed}
        else
          {[], item}
        end
      end)
      {Enum.concat(res), changed}
    end
  end

  @doc ~S"""
  Obtain a list of values from a lens

      iex> Lens.keys([:a, :c]) |> Lens.to_list(%{a: 1, b: 2, c: 3})
      [1, 3]
  """
  def to_list(lens, data) do
    {list, _} = get_and_map(lens, data, &{&1, &1})
    list
  end

  @doc ~S"""
  Perform a side effect on each value from a lens

      iex> data = %{a: 1, b: 2, c: 3}
      iex> fun = fn -> Lens.keys([:a, :c]) |> Lens.each(data, &IO.inspect/1) end
      iex> import ExUnit.CaptureIO
      iex> capture_io(fun)
      "1\n3\n"
  """
  def each(lens, data, fun) do
    {_, _} = get_and_map(lens, data, &{nil, fun.(&1)})
    :ok
  end

  @doc ~S"""
  Obtain the updated version of data by applying fun on lens.

      iex> data = [1, 2, 3, 4]
      iex> Lens.filter(&Integer.is_odd/1) |> Lens.map(data, fn v -> v + 10 end)
      [11, 2, 13, 4]
  """
  def map(lens, data, fun) do
    {_, changed} = get_and_map(lens, data, &{nil, fun.(&1)})
    changed
  end

  @doc ~S"""
  Get a tuple of original values and the updated data by applying fun on lens.

  The mapping function takes a value and must return a tuple with old and update values.

      iex> data = [1, 2, 3]
      iex> Lens.filter(&Integer.is_odd/1) |> Lens.get_and_map(data, fn v -> {v, v + 10} end)
      {[1, 3], [11, 2, 13]}
  """
  def get_and_map(lens, data, fun) do
    lens.(data, fun)
  end

  @doc ~S"""
  Executes `to_list` and returns the first item if the list has only one item otherwise the full list.
  """
  def get(lens, data) do
    to_list(lens, data) |> fn [x] -> x; x -> x end.()
  end


  defp do_recur(lens, data, fun) do
    {res, changed} = get_and_map(lens, data, fn item ->
      {results, changed1} = do_recur(lens, item, fun)
      {res_parent, changed2} = fun.(changed1)
      {[res_parent | results], changed2}
    end)

    {Enum.concat(res), changed}
  end

  defp get_at_index(data, index) when is_tuple(data), do: elem(data, index)
  defp get_at_index(data, index), do: Enum.at(data, index)

  defp set_at_index(data, index, value) when is_tuple(data), do: put_elem(data, index, value)
  defp set_at_index(data, index, value) when is_list(data) do
    List.update_at(data, index, fn _ -> value end)
  end

  defp get_at_key(data, key) when is_map(data), do: Map.get(data, key)
  defp get_at_key(data, key), do: Access.get(data, key)

  defp set_at_key(data, key, value) when is_map(data), do: Map.put(data, key, value)
  defp set_at_key(data, key, value) do
    {_, updated} = Access.get_and_update(data, key, fn _ -> {nil, value} end)
    updated
  end

end

