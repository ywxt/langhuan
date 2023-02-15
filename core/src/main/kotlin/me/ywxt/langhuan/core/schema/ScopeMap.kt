package me.ywxt.langhuan.core.schema

class ScopeMap<V>(
    parentMap: Map<String, V>?,
    variables: Map<String, V>
) : Map<String, V> {
    private val map = (parentMap?.toMutableMap() ?: mutableMapOf()) + variables
    override val entries: Set<Map.Entry<String, V>> = map.entries
    override val keys: Set<String> = map.keys
    override val size: Int = map.size
    override val values: Collection<V> = map.values
    override fun containsKey(key: String): Boolean = map.containsKey(key)

    override fun containsValue(value: V): Boolean = map.containsValue(value)

    override fun get(key: String): V? = map[key]

    override fun isEmpty(): Boolean = map.isEmpty()
}
