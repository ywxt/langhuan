package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.Err
import com.github.michaelbull.result.Ok
import com.github.michaelbull.result.Result
import me.ywxt.langhuan.core.ConfigParsingError
import org.jsoup.Jsoup
import org.jsoup.select.Evaluator
import org.jsoup.select.QueryParser

class ParsedSources(val document: String) {
    private val cssSelectorSource: ParsedSource<SelectorSource.SelectorPath> by lazy {
        SelectorSource(document)
    }
    private val jsonSource: ParsedSource<String> by lazy {
        JSONSource(document)
    }

    fun getSelectorSource(): ParsedSource<SelectorSource.SelectorPath> = cssSelectorSource

    fun getJSONSource(): ParsedSource<String> = jsonSource
}

sealed class ParsedSource<T>(val document: String) {
    abstract fun parse(path: T): Iterable<String>
}

class SelectorSource(document: String) : ParsedSource<SelectorSource.SelectorPath>(document) {
    data class SelectorPath(val evaluator: Evaluator, val attribute: String)

    private val doc = Jsoup.parse(document)
    override fun parse(path: SelectorPath): Iterable<String> = doc.select(path.evaluator).map { element ->
        if (path.attribute.compareTo("html", true) == 0) {
            element.outerHtml()
        } else if (path.attribute.compareTo("text", true) == 0) {
            element.text()
        } else {
            element.attr(path.attribute)
        }
    }
}

class JSONSource(document: String) : ParsedSource<String>(document) {
    override fun parse(path: String): Iterable<String> {
        TODO("Not yet implemented")
    }
}

sealed class Parser(val path: String) {
    abstract fun parse(sources: ParsedSources): Iterable<String>

    companion object {
        operator fun invoke(path: String, isList: Boolean): Result<Parser, ConfigParsingError> {
            val sections = path.split("@@")
            if (sections.size < 2) {
                return Err(
                    ConfigParsingError(
                        "the number of sections for list parser path must be more than 1. yours is " +
                            "${sections.size}. \n path: (`$path`)."
                    )
                )
            }
            return when (sections[0]) {
                "css" -> parseSelectorParser(sections, isList)
                else -> Err(ConfigParsingError("Unknown path type (`${sections[0]}`). \n path: $path"))
            }
        }

        private fun parseSelectorParser(
            sections: List<String>,
            isList: Boolean
        ): Result<Parser, ConfigParsingError> = if (isList) {
            Ok(SelectorParser(sections[1], sections.getOrElse(2) { "html" }))
        } else {
            Ok(SelectorParser(sections[1], sections.getOrElse(2) { "text" }))
        }
    }
}

class SelectorParser(selector: String, attribute: String) : Parser("$selector@@$attribute") {
    private val selectorPath = SelectorSource.SelectorPath(QueryParser.parse(selector), attribute)
    override fun parse(sources: ParsedSources): Iterable<String> =
        sources.getSelectorSource().parse(selectorPath)
}

class JSONParser(path: String) : Parser(path) {
    override fun parse(sources: ParsedSources): Iterable<String> {
        TODO("Not yet implemented")
    }
}
