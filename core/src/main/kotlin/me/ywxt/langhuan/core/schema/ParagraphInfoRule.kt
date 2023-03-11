package me.ywxt.langhuan.core.schema

data class ParagraphInfoRule(
    val request: RuleRequest,
    val content: ParsableField,
    val nextPage: NextPageRule,
)
