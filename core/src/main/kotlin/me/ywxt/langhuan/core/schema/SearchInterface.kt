package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class SearchInterface(
    private val rule: SearchRule,
) : ResourceInterface<SearchResultItem> {

    override fun init(env: InterfaceEnvironment) {
        env.setVariable(Variables.PAGE, 0)
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment,
    ): Either<InterfaceError, ResourceValue<SearchResultItem>> = either {
        val items = rule.area.parseList(env, sources).bind().map { source ->
            val itemSources = ParsedSources(source)
            val title = rule.title.parseNonNullableFiled(env, itemSources).bind()
            val infoUrl = rule.infoUrl.parseNonNullableFiled(env, sources).bind()
            val author = rule.author?.parseField(env, itemSources)?.bind()
            val description = rule.description?.parseField(env, itemSources)?.bind()
            val extraTags = rule.extraTags?.parseList(env, itemSources)?.bind()
            SearchResultItem(title, infoUrl, author, description, extraTags)
        }
        val hasNextPage = rule.hasNextPage.hasNextPage(env, sources, items).bind()
        env.setVariable("page", env.getVariable("page") as Int + 1)
        ResourceValue.List(items, hasNextPage)
    }
}
