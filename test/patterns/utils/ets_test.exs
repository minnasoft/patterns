defmodule Patterns.Utils.ETSTest do
  use ExUnit.Case, async: true

  alias Patterns.Utils.ETS

  setup do
    table = ETS.new([], access: :public)

    %{table: table}
  end

  describe "new/2" do
    test "creates an empty table with defaults" do
      table = ETS.new()

      assert ETS.to_list(table) == []
      assert :ets.info(table, :type) == :set
      assert :ets.info(table, :protection) == :protected
    end

    test "treats one list argument as options" do
      table = ETS.new(access: :public, read_concurrency: true)

      assert :ets.info(table, :protection) == :public
      assert :ets.info(table, :read_concurrency)
    end

    test "treats one non-list argument as enumerable data" do
      table = ETS.new(%{key: :value})

      assert ETS.fetch(table, :key) == {:ok, :value}
    end

    test "creates and seeds a table" do
      table = ETS.new([{:key, :value}], access: :public)

      assert ETS.fetch(table, :key) == {:ok, :value}
    end

    test "supports all table types" do
      for type <- [:set, :ordered_set] do
        table = ETS.new([{:key, :first}, {:key, :second}], type: type, access: :public)

        assert :ets.info(table, :type) == type
        assert ETS.fetch(table, :key) == {:ok, :second}
      end

      for type <- [:bag, :duplicate_bag] do
        table = ETS.new([{:key, :first}, {:key, :second}], type: type, access: :public)

        assert :ets.info(table, :type) == type
        assert Enum.sort(ETS.get(table, :key)) == [:first, :second]
      end
    end

    test "preserves duplicate objects only for duplicate bags" do
      bag = ETS.new([{:key, :same}, {:key, :same}], type: :bag, access: :public)
      duplicate_bag = ETS.new([{:key, :same}, {:key, :same}], type: :duplicate_bag, access: :public)

      assert ETS.get(bag, :key) == [:same]
      assert ETS.get(duplicate_bag, :key) == [:same, :same]
    end

    test "translates ETS options" do
      table =
        ETS.new([],
          access: :public,
          read_concurrency: true,
          write_concurrency: :auto,
          decentralized_counters: true,
          compressed: true
        )

      assert :ets.info(table, :protection) == :public
      assert :ets.info(table, :read_concurrency)
      assert :ets.info(table, :write_concurrency) == :auto
      assert :ets.info(table, :decentralized_counters)
      assert :ets.info(table, :compressed)
    end

    test "supports false flag options" do
      table = ETS.new(named_table: false, compressed: false, read_concurrency: false, write_concurrency: false)

      assert is_reference(table)
      assert :ets.info(table, :compressed) == false
      assert :ets.info(table, :read_concurrency) == false
      assert :ets.info(table, :write_concurrency) == false
    end

    test "supports private tables" do
      table = ETS.new(access: :private)

      assert :ets.info(table, :protection) == :private
    end

    test "supports heir options" do
      table = ETS.new(heir: :none)
      heir_table = ETS.new(heir: {self(), :data})

      assert :ets.info(table, :heir) == :none
      assert :ets.info(heir_table, :heir) == self()
    end

    test "supports named tables" do
      name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"

      assert ETS.new([], name: name, named_table: true) == name
      assert :ets.info(name, :name) == name
    end

    test "raises on unknown options" do
      assert_raise ArgumentError, "unknown ETS option :nope", fn ->
        ETS.new([], nope: true)
      end

      assert_raise ArgumentError, "unknown ETS option :keypos", fn ->
        ETS.new(keypos: 2)
      end
    end

    test "raises on invalid option values" do
      assert_raise ArgumentError, ~r/invalid ETS option :type/, fn ->
        ETS.new([], type: :nope)
      end

      assert_raise ArgumentError, ~r/invalid ETS option :access/, fn ->
        ETS.new([], access: :nope)
      end

      assert_raise ArgumentError, ~r/invalid ETS option :named_table/, fn ->
        ETS.new([], named_table: :yes)
      end

      assert_raise ArgumentError, ~r/invalid ETS option :compressed/, fn ->
        ETS.new([], compressed: :yes)
      end

      assert_raise ArgumentError, "invalid ETS option :heir", fn ->
        ETS.new([], heir: {:not_a_pid, :data})
      end

      assert_raise ArgumentError, ~r/invalid ETS option :read_concurrency/, fn ->
        ETS.new([], read_concurrency: :yes)
      end

      assert_raise ArgumentError, ~r/invalid ETS option :write_concurrency/, fn ->
        ETS.new([], write_concurrency: :yes)
      end

      assert_raise ArgumentError, ~r/invalid ETS option :decentralized_counters/, fn ->
        ETS.new([], decentralized_counters: :yes)
      end

      assert_raise ArgumentError, ~r/invalid ETS option :name/, fn ->
        ETS.new([], name: "not_an_atom")
      end
    end

    test "raises on malformed options" do
      assert_raise ArgumentError, "invalid ETS option :public", fn ->
        ETS.new([:public])
      end
    end
  end

  describe "fetch/2" do
    test "returns tagged values", %{table: table} do
      assert ETS.fetch(table, :missing) == :error

      assert ETS.put(table, :key, :value) == table

      assert ETS.fetch(table, :key) == {:ok, :value}
    end

    test "returns lists for bag-style tables" do
      table = ETS.new([{:key, :first}, {:key, :second}], type: :duplicate_bag, access: :public)

      assert {:ok, values} = ETS.fetch(table, :key)
      assert Enum.sort(values) == [:first, :second]
    end

    test "returns a list for single bag values" do
      for type <- [:bag, :duplicate_bag] do
        table = ETS.new([{:key, :value}], type: type, access: :public)

        assert ETS.fetch(table, :key) == {:ok, [:value]}
      end
    end
  end

  describe "get/3" do
    test "returns values or defaults", %{table: table} do
      assert ETS.get(table, :missing) == nil
      assert ETS.get(table, :missing, :default) == :default

      assert ETS.put(table, :key, :value) == table

      assert ETS.get(table, :key, :default) == :value
    end

    test "returns lists for bag-style tables" do
      table = ETS.new([{:key, :first}, {:key, :second}], type: :bag, access: :public)

      assert Enum.sort(ETS.get(table, :key)) == [:first, :second]
    end

    test "returns lists for duplicate bag tables" do
      table = ETS.new([{:key, :value}], type: :duplicate_bag, access: :public)

      assert ETS.get(table, :key) == [:value]
    end
  end

  describe "update/4" do
    test "updates existing values", %{table: table} do
      assert ETS.put(table, :count, 1) == table

      assert ETS.update(table, :count, 0, &(&1 + 1)) == table
      assert ETS.get(table, :count) == 2
    end

    test "uses initial value when missing", %{table: table} do
      assert ETS.update(table, :count, 0, &(&1 + 1)) == table
      assert ETS.get(table, :count) == 1
    end

    test "supports ordered set tables" do
      table = ETS.new([count: 1], type: :ordered_set)

      assert ETS.update(table, :count, 0, &(&1 + 1)) == table
      assert ETS.get(table, :count) == 2
    end

    test "raises for bag-style tables" do
      for type <- [:bag, :duplicate_bag] do
        table = ETS.new([], type: type, access: :public)

        assert_raise ArgumentError, "ETS.update/4 only supports :set and :ordered_set tables", fn ->
          ETS.update(table, :key, 0, &(&1 + 1))
        end
      end
    end
  end

  describe "delete/2" do
    test "removes values", %{table: table} do
      assert ETS.put(table, :key, :value) == table
      assert ETS.delete(table, :key) == table

      assert ETS.fetch(table, :key) == :error
    end

    test "removes all values for bag-style tables" do
      table = ETS.new([{:key, :first}, {:key, :second}], type: :bag, access: :public)

      assert Enum.sort(ETS.get(table, :key)) == [:first, :second]

      assert ETS.delete(table, :key) == table

      assert ETS.fetch(table, :key) == :error
    end
  end

  describe "to_list/1" do
    test "returns table entries", %{table: table} do
      assert ETS.put(table, :first, 1) == table
      assert ETS.put(table, :second, 2) == table

      assert Enum.sort(ETS.to_list(table)) == [first: 1, second: 2]
    end

    test "returns duplicate entries for duplicate bags" do
      table = ETS.new([{:key, :same}, {:key, :same}], type: :duplicate_bag, access: :public)

      assert ETS.to_list(table) == [key: :same, key: :same]
    end
  end

  describe "set?/1" do
    test "returns true only for set tables" do
      set = ETS.new(type: :set)
      ordered_set = ETS.new(type: :ordered_set)
      bag = ETS.new(type: :bag)
      duplicate_bag = ETS.new(type: :duplicate_bag)

      assert ETS.set?(set)
      refute ETS.set?(ordered_set)
      refute ETS.set?(bag)
      refute ETS.set?(duplicate_bag)
    end
  end

  describe "ordered_set?/1" do
    test "returns true only for ordered set tables" do
      set = ETS.new(type: :set)
      ordered_set = ETS.new(type: :ordered_set)
      bag = ETS.new(type: :bag)
      duplicate_bag = ETS.new(type: :duplicate_bag)

      refute ETS.ordered_set?(set)
      assert ETS.ordered_set?(ordered_set)
      refute ETS.ordered_set?(bag)
      refute ETS.ordered_set?(duplicate_bag)
    end
  end

  describe "bag?/1" do
    test "returns true only for bag tables" do
      set = ETS.new(type: :set)
      ordered_set = ETS.new(type: :ordered_set)
      bag = ETS.new(type: :bag)
      duplicate_bag = ETS.new(type: :duplicate_bag)

      refute ETS.bag?(set)
      refute ETS.bag?(ordered_set)
      assert ETS.bag?(bag)
      refute ETS.bag?(duplicate_bag)
    end
  end

  describe "duplicate_bag?/1" do
    test "returns true only for duplicate bag tables" do
      set = ETS.new(type: :set)
      ordered_set = ETS.new(type: :ordered_set)
      bag = ETS.new(type: :bag)
      duplicate_bag = ETS.new(type: :duplicate_bag)

      refute ETS.duplicate_bag?(set)
      refute ETS.duplicate_bag?(ordered_set)
      refute ETS.duplicate_bag?(bag)
      assert ETS.duplicate_bag?(duplicate_bag)
    end
  end
end
