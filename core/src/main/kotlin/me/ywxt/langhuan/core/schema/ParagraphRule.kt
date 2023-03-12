package me.ywxt.langhuan.core.schema

data class ParagraphRule(
    val request: RuleRequest,
    val content: ParsableField,
    val nextPage: NextPageRule,
)
