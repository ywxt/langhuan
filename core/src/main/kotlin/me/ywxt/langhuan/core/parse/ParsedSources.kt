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
package me.ywxt.langhuan.core.parse

class ParsedSources(val document: String) {
    private val selectorSource: ParsedSource<ParsedSelectorSource.SelectorPath> by lazy {
        ParsedSelectorSource(document)
    }
    private val jsonSource: ParsedSource<String> by lazy {
        ParsedJSONSource(document)
    }
    private val unitSource: ParsedSource<Unit> = ParsedUnitSource

    @Suppress("UNCHECKED_CAST")
    fun <T> getSource(type: ParsedSourceType<T>): ParsedSource<T> = when (type) {
        ParsedSourceType.UnitSource -> unitSource as ParsedSource<T>
        ParsedSourceType.JSONSource -> jsonSource as ParsedSource<T>
        ParsedSourceType.SelectorSource -> selectorSource as ParsedSource<T>
    }
}
