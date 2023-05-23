/// Type of large-scale storage tables.
module initia_std::table {
    use std::error;
    use std::vector;
    use std::bcs;
    use std::option::{Self, Option};

    // TODO: native code should not use reasons to signal logical type of error. Instead,
    // use Errors::ALREADY_PUBLISHED and Errors::NOT_PUBLISHED.
    const EALREADY_EXISTS: u64 = 100;
    // native code raises this with Errors::invalid_arguments()
    const ENOT_FOUND: u64 = 101;
    const ENOT_EMPTY: u64 = 102;

    /// Type of tables
    struct Table<phantom K: copy + drop, phantom V> has store {
        handle: address,
        length: u64,
    }

    /// Type of table iterators
    struct TableIter has drop {
        iterator_id: u64,
    }

    /// Create a new Table.
    public fun new<K: copy + drop, V: store>(): Table<K, V> {
        Table {
            handle: new_table_handle<K, V>(),
            length: 0,
        }
    }

    /// Destroy a table. The table must be empty to succeed.
    public fun destroy_empty<K: copy + drop, V>(table: Table<K, V>) {
        assert!(table.length == 0, error::invalid_state(ENOT_EMPTY));
        destroy_empty_box<K, V, Box<V>>(&table);
        drop_unchecked_box<K, V, Box<V>>(table)
    }

    /// Add a new entry to the table. Aborts if an entry for this
    /// key already exists. The entry itself is not stored in the
    /// table, and cannot be discovered from it.
    public fun add<K: copy + drop, V>(table: &mut Table<K, V>, key: K, val: V) {
        add_box<K, V, Box<V>>(table, key, Box { val });
        table.length = table.length + 1
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow<K: copy + drop, V>(table: &Table<K, V>, key: K): &V {
        &borrow_box<K, V, Box<V>>(table, key).val
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Returns specified default value if there is no entry for `key`.
    public fun borrow_with_default<K: copy + drop, V>(table: &Table<K, V>, key: K, default: &V): &V {
        if (!contains(table, copy key)) {
            default
        } else {
            borrow(table, copy key)
        }
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow_mut<K: copy + drop, V>(table: &mut Table<K, V>, key: K): &mut V {
        &mut borrow_box_mut<K, V, Box<V>>(table, key).val
    }

    /// Returns the length of the table, i.e. the number of entries.
    public fun length<K: copy + drop, V>(table: &Table<K, V>): u64 {
        table.length
    }

    /// Returns true if this table is empty.
    public fun empty<K: copy + drop, V>(table: &Table<K, V>): bool {
        table.length == 0
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Insert the pair (`key`, `default`) first if there is no entry for `key`.
    public fun borrow_mut_with_default<K: copy + drop, V: drop>(table: &mut Table<K, V>, key: K, default: V): &mut V {
        if (!contains(table, copy key)) {
            add(table, copy key, default)
        };
        borrow_mut(table, key)
    }

    /// Insert the pair (`key`, `value`) if there is no entry for `key`.
    /// update the value of the entry for `key` to `value` otherwise
    public fun upsert<K: copy + drop, V: drop>(table: &mut Table<K, V>, key: K, value: V) {
        if (!contains(table, copy key)) {
            add(table, copy key, value)
        } else {
            let ref = borrow_mut(table, key);
            *ref = value;
        };
    }

    /// Remove from `table` and return the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun remove<K: copy + drop, V>(table: &mut Table<K, V>, key: K): V {
        let Box { val } = remove_box<K, V, Box<V>>(table, key);
        table.length = table.length - 1;
        val
    }

    /// Returns true iff `table` contains an entry for `key`.
    public fun contains<K: copy + drop, V>(table: &Table<K, V>, key: K): bool {
        contains_box<K, V, Box<V>>(table, key)
    }

    #[test_only]
    /// Testing only: allows to drop a table even if it is not empty.
    public fun drop_unchecked<K: copy + drop, V>(table: Table<K, V>) {
        drop_unchecked_box<K, V, Box<V>>(table)
    }

    /// Create iterator for `table`.
    /// A user has to check `prepare` before calling `next` to prevent abort
    /// 
    /// let iter = table::iter(&t, start, end, order);
    /// loop {
    ///     if (!table::prepare<K, V>(&mut iter)) {
    ///         break;
    ///     }
    /// 
    ///     let (key, value) = table::next<K, V>(&mut iter);
    /// } 
    public fun iter<K: copy + drop, V>(
        table: &Table<K, V>,
        start: Option<K>, /* inclusive */
        end: Option<K>, /* exclusive */
        order: u8 /* 1: Ascending, 2: Descending */,
    ): TableIter {
        let start_bytes: vector<u8> = if (option::is_some(&start)) {
            bcs::to_bytes<K>(&option::extract(&mut start))
        } else {
            vector::empty()
        };

        let end_bytes: vector<u8> = if (option::is_some(&end)) {
            bcs::to_bytes<K>(&option::extract(&mut end))
        } else {
            vector::empty()
        };

        let iterator_id = new_table_iter<K, V, Box<V>>(table, start_bytes, end_bytes, order);
        TableIter {
            iterator_id,
        }
    }

    public fun prepare<K: copy + drop, V>(table_iter: &mut TableIter): bool {
        prepare_box<K, V, Box<V>>(table_iter)
    }

    public fun next<K: copy + drop, V>(table_iter: &mut TableIter): (K, &V) {
        let (key, box) = next_box<K, V, Box<V>>(table_iter);
        (key, &box.val)
    }

    // ======================================================================================================
    // Internal API

    /// Wrapper for values. Required for making values appear as resources in the implementation.
    struct Box<V> has key, drop, store {
        val: V
    }

    // Primitives which take as an additional type parameter `Box<V>`, so the implementation
    // can use this to determine serialization layout.
    native fun new_table_handle<K, V>(): address;

    native fun add_box<K: copy + drop, V, B>(table: &mut Table<K, V>, key: K, val: Box<V>);

    native fun borrow_box<K: copy + drop, V, B>(table: &Table<K, V>, key: K): &Box<V>;

    native fun borrow_box_mut<K: copy + drop, V, B>(table: &mut Table<K, V>, key: K): &mut Box<V>;

    native fun contains_box<K: copy + drop, V, B>(table: &Table<K, V>, key: K): bool;

    native fun remove_box<K: copy + drop, V, B>(table: &mut Table<K, V>, key: K): Box<V>;

    native fun destroy_empty_box<K: copy + drop, V, B>(table: &Table<K, V>);

    native fun drop_unchecked_box<K: copy + drop, V, B>(table: Table<K, V>);

    native fun new_table_iter<K: copy + drop, V, B>(
        table: &Table<K, V>,
        start: vector<u8>,
        end: vector<u8>,
        order: u8
    ): u64;

    native fun next_box<K: copy + drop, V, B>(table_iter: &mut TableIter): (K, &Box<V>);

    native fun prepare_box<K: copy + drop, V, B>(table_iter: &mut TableIter): bool;

    // ======================================================================================================
    // Tests

    #[test_only]
    struct TableHolder<phantom K: copy + drop, phantom V: drop> has key {
        t: Table<K, V>
    }

    #[test(account = @0x1)]
    fun test_upsert(account: signer) {
        let t = new<u64, u8>();
        let key: u64 = 111;
        let error_code: u64 = 1;
        assert!(!contains(&t, key), error_code);
        upsert(&mut t, key, 12);
        assert!(*borrow(&t, key) == 12, error_code);
        upsert(&mut t, key, 23);
        assert!(*borrow(&t, key) == 23, error_code);

        move_to(&account, TableHolder { t });
    }

    #[test(account = @0x1)]
    fun test_borrow_with_default(account: signer) {
        let t = new<u64, u8>();
        let key: u64 = 100;
        let error_code: u64 = 1;
        assert!(!contains(&t, key), error_code);
        assert!(*borrow_with_default(&t, key, &12) == 12, error_code);
        add(&mut t, key, 1);
        assert!(*borrow_with_default(&t, key, &12) == 1, error_code);

        move_to(&account, TableHolder{ t });
    }
}
