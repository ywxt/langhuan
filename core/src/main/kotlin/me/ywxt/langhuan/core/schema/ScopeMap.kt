/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */
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
