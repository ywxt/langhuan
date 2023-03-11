package me.ywxt.langhuan.core.schema

data class ContentsRule(
    val request: RuleRequest,
    val area: ParsableField,
    val title: ParsableField,
    val chapterUrl: ParsableField,
    val nextPage: NextPageRule,
)
