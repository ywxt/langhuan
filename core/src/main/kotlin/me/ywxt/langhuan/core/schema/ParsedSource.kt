package me.ywxt.langhuan.core.schema

import me.ywxt.langhuan.core.utils.paragraphs
import org.jsoup.Jsoup
import org.jsoup.select.Evaluator

sealed class ParsedSource<T>(val document: String) {
    abstract fun parse(path: T): Sequence<String>
}

class JSONSource(document: String) : ParsedSource<String>(document) {
    override fun parse(path: String): Sequence<String> {
        TODO("Not yet implemented")
    }
}

object UnitSource : ParsedSource<Unit>("") {
    const val value = ""
    override fun parse(path: Unit): Sequence<String> = sequenceOf(value)
}

class SelectorSource(document: String) : ParsedSource<SelectorSource.SelectorPath>(document) {
    data class SelectorPath(val evaluator: Evaluator, val attribute: String)

    private val doc = Jsoup.parse(document)

    override fun parse(path: SelectorPath): Sequence<String> =
        doc.select(path.evaluator).asSequence().flatMap { element ->
            if (path.attribute.compareTo("html", true) == 0) {
                sequenceOf(element.outerHtml())
            } else if (path.attribute.compareTo("text", true) == 0) {
                sequenceOf(element.text())
            } else if (path.attribute.compareTo("para", true) == 0) {
                element.paragraphs()
            } else {
                sequenceOf(element.attr(path.attribute))
            }
        }
}
