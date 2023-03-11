package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import kotlinx.coroutines.flow.map
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class ContentsInterface(private val rule: ContentsRule) : ResourceInterface<ContentsItem> {
    override fun init(env: InterfaceEnvironment) {
        env.initPage()
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment,
    ): Either<InterfaceError, ResourceValue<ContentsItem>> = either {
        val contents = rule.area.parseList(env, sources).bind().map { source ->
            val itemSources = ParsedSources(source)
            val title = rule.title.parseNonNullableFiled(env, itemSources).bind()
            val chapterUrl = rule.chapterUrl.parseNonNullableFiled(env, itemSources).bind()
            ContentsItem(title, chapterUrl)
        }
        env.setVariable(Variables.EMPTY_RESULT, contents.isEmpty())
        val hasNextPage = rule.nextPage.nextPageUrl(env, sources).bind()
        env.incPage()
        ResourceValue.List(contents, hasNextPage)
    }
}
