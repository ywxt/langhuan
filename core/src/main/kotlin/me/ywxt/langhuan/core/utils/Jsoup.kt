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
