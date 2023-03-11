package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import kotlinx.coroutines.flow.map
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class ChapterInterface(private val rule: ParagraphInfoRule) : ResourceInterface<ParagraphInfo> {
    override fun init(env: InterfaceEnvironment) {
        env.initPage()
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment,
    ): Either<InterfaceError, ResourceValue<ParagraphInfo>> = either {
        val content = rule.content.parseList(env, sources).bind().map {
            ParagraphInfo(it)
        }
        env.setVariable(Variables.EMPTY_RESULT, content.isEmpty())
        val nextPageUrl = rule.nextPage.nextPageUrl(env, sources).bind()
        env.incPage()
        ResourceValue.List(content, nextPageUrl)
    }
}
