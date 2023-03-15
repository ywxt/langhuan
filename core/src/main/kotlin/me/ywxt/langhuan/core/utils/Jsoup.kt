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
package me.ywxt.langhuan.core.utils

import org.jsoup.internal.StringUtil
import org.jsoup.nodes.Element

fun Element.paragraphs(): Sequence<String> = sequence {
    this@paragraphs.textNodes().forEach { node ->
        normaliseWhitespace(node.wholeText)?.let { yield(it) }
    }
}

fun normaliseWhitespace(text: String): String? = removeWhitespace(text)

private fun removeWhitespace(string: String): String? {
    var lastWasWhite = false
    var reachedNonWhite = false
    val len = string.length
    var c: Int
    var i = 0
    val accum = StringUtil.borrowBuilder()
    while (i < len) {
        c = string.codePointAt(i)
        if (StringUtil.isWhitespace(c)) {
            if (!reachedNonWhite || lastWasWhite) {
                i += Character.charCount(c)
                continue
            }
            accum.append(' ')
            lastWasWhite = true
        } else if (!StringUtil.isInvisibleChar(c)) {
            accum.appendCodePoint(c)
            lastWasWhite = false
            reachedNonWhite = true
        }
        i += Character.charCount(c)
    }
    val result = StringUtil.releaseBuilder(accum)
    return result.ifEmpty {
        null
    }
}
