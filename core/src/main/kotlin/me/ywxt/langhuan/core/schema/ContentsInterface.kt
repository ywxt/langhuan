package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
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
        env: InterfaceEnvironment,
        sources: ParsedSources,
    ): Either<InterfaceError, ResourceValue<ContentsItem>> = either {
        val contents = rule.area.parseList(env, sources).bind().map { source ->
            val itemSources = ParsedSources(source)
            val title = rule.title.parseNonNullableFiled(env, itemSources).bind()
            val chapterUrl = rule.chapterUrl.parseNonNullableFiled(env, itemSources).bind()
            ContentsItem(title, chapterUrl)
        }
        env.setVariable(Variables.EMPTY_RESULT, contents.isEmpty())
        val hasNextPage = rule.nextPage.nextPageUrl(env, sources).bind()
        ResourceValue.List(contents, hasNextPage)
    }

    override fun afterParse(env: InterfaceEnvironment, value: ResourceValue<ContentsItem>) {
        env.incPage()
        env.setNextPageUrl(Variables.CONTENTS_URL, value)
    }
}
