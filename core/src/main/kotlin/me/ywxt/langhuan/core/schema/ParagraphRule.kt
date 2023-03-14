package me.ywxt.langhuan.core.schema

data class ParagraphRule(
    val request: RuleRequest,
    val paragraph: ParsableField,
    val nextPage: NextPageRule,
)
