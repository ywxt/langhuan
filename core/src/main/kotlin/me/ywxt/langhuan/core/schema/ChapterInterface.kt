package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class ChapterInterface(private val rule: ParagraphRule) : ResourceInterface<ParagraphInfo> {
    override fun init(env: InterfaceEnvironment) {
        env.initPage()
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun process(
        env: InterfaceEnvironment,
        sources: ParsedSources,
    ): Either<InterfaceError, ResourceValue<ParagraphInfo>> = either {
        val content = rule.content.parseList(env, sources).bind().map {
            ParagraphInfo(it)
        }
        env.setVariable(Variables.EMPTY_RESULT, content.isEmpty())
        val nextPageUrl = rule.nextPage.nextPageUrl(env, sources).bind()
        val value = ResourceValue.List(content, nextPageUrl)
        afterParse(env, value)
        value
    }

    private fun afterParse(env: InterfaceEnvironment, value: ResourceValue<ParagraphInfo>) {
        env.incPage()
        env.setNextPageUrl(Variables.CHAPTER_URL, value)
    }
}
