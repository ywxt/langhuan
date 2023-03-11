package me.ywxt.langhuan.core.schema

import arrow.core.Either
import me.ywxt.langhuan.core.ConfigParsingError
import org.jsoup.select.QueryParser

sealed class Parser(val type: String, val path: String) {
    abstract fun parse(sources: ParsedSources): Sequence<String>

    override fun toString(): String {
        return "`$type Parser, path: $path`"
    }

    companion object {
        operator fun invoke(path: String, isList: Boolean): Either<ConfigParsingError, Parser> {
            val sections = path.split("@@")
            return when (sections[0]) {
                "", "unit" -> Either.Right(UnitParser)
                "css" -> parseSelectorParser(path, sections, isList)
                else -> Either.Left(ConfigParsingError("Unknown path type (`${sections[0]}`). \n path: `$path`"))
            }
        }

        private fun parseSelectorParser(
            path: String,
            sections: List<String>,
            isList: Boolean,
        ): Either<ConfigParsingError, Parser> {
            if (sections.size < 2) {
                return Either.Left(
                    ConfigParsingError(
                        "The selector of css parser can not be empty. \n path: `$path`"
                    )
                )
            }
            val defaultAttr = if (isList) {
                "html"
            } else {
                "text"
            }
            return Either.catch { SelectorParser(sections[1], sections.getOrElse(2) { defaultAttr }) }
                .mapLeft { ConfigParsingError(it.stackTraceToString()) }
        }
    }
}

class SelectorParser(selector: String, attribute: String) : Parser("css", "$selector@@$attribute") {
    private val selectorPath = SelectorSource.SelectorPath(QueryParser.parse(selector), attribute)
    override fun parse(sources: ParsedSources): Sequence<String> = sources.selectorSource.parse(selectorPath)
}

class JSONParser(path: String) : Parser("json", path) {
    override fun parse(sources: ParsedSources): Sequence<String> {
        TODO("Not yet implemented")
    }
}

object UnitParser : Parser("raw", "") {
    override fun parse(sources: ParsedSources): Sequence<String> = sources.unitSource.parse(Unit)
}
