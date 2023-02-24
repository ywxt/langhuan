package me.ywxt.langhuan.core.schema

class ParsedSources(val document: String) {
    private val cssSelectorSource: ParsedSource<String> by lazy {
        SelectorSource(document)
    }
    private val jsonSource: ParsedSource<String> by lazy {
        JSONSource(document)
    }

    fun getSelectorSource(): ParsedSource<String> = cssSelectorSource

    fun getJSONSource(): ParsedSource<String> = jsonSource
}

sealed class ParsedSource<T>(val document: String) {
    abstract fun parse(path: T): Iterable<String>
}

class SelectorSource(document: String) : ParsedSource<String>(document) {
    override fun parse(path: String): Iterable<String> {
        TODO("Not yet implemented")
    }
}

class JSONSource(document: String) : ParsedSource<String>(document) {
    override fun parse(path: String): Iterable<String> {
        TODO("Not yet implemented")
    }
}

sealed class Parser(val path: String) {
    abstract fun parse(source: ParsedSources): Iterable<String>
}

class SelectorParser(selector: String) : Parser(selector) {
    override fun parse(source: ParsedSources): Iterable<String> {
        TODO("Not yet implemented")
    }
}

class JSONParser(path: String) : Parser(path) {
    override fun parse(source: ParsedSources): Iterable<String> {
        TODO("Not yet implemented")
    }
}
