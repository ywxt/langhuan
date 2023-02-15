package me.ywxt.langhuan.core.schema

class ParsedSources(val document: String) {
    val selectorSource by lazy {
        SelectorSource(document)
    }
    val jsonSource by lazy {
        JSONSource(document)
    }
}

sealed class ParsedSource(val document: String)

class SelectorSource(document: String) : ParsedSource(document)

class JSONSource(document: String) : ParsedSource(document)

sealed class Parser(val path: String) {
    abstract fun parse(source: ParsedSources): String
}

class SelectorParser(selector: String) : Parser(selector) {
    override fun parse(source: ParsedSources): String {
        TODO("Not yet implemented")
    }
}

class JSONParser(path: String) : Parser(path) {
    override fun parse(source: ParsedSources): String {
        TODO("Not yet implemented")
    }
}
