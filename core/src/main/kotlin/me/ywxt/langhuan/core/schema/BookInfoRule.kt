package me.ywxt.langhuan.core.schema

data class BookInfoRule(
    val request: RuleRequest,
    val title: ParsableField,
    val contentsUrl: ParsableField,
    val author: ParsableField? = null,
    val description: ParsableField? = null,
    val extraTags: ParsableField? = null,
)
