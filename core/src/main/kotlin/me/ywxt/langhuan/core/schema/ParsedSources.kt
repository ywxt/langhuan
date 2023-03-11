package me.ywxt.langhuan.core.schema

class ParsedSources(val document: String) {
    val selectorSource: ParsedSource<SelectorSource.SelectorPath> by lazy {
        SelectorSource(document)
    }
    val jsonSource: ParsedSource<String> by lazy {
        JSONSource(document)
    }
    val rawSource: ParsedSource<Unit> = RawSource
}
