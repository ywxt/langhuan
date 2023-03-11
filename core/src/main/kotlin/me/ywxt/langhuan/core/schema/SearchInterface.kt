package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class SearchInterface(
    private val rule: SearchRule,
) : ResourceInterface<SearchResultItem> {

    override fun init(env: InterfaceEnvironment) {
        env.initPage()
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun parse(
        env: InterfaceEnvironment,
        sources: ParsedSources,
    ): Either<InterfaceError, ResourceValue<SearchResultItem>> = either {
        val items = rule.area.parseList(env, sources).bind().map { source ->
            val itemSources = ParsedSources(source)
            val title = rule.title.parseNonNullableFiled(env, itemSources).bind()
            val infoUrl = rule.infoUrl.parseNonNullableFiled(env, sources).bind()
            val author = rule.author?.parseField(env, itemSources)?.bind()
            val description = rule.description?.parseField(env, itemSources)?.bind()
            val extraTags = rule.extraTags?.parseList(env, itemSources)?.bind()?.toList()
            SearchResultItem(title, infoUrl, author, description, extraTags)
        }
        env.setVariable(Variables.EMPTY_RESULT, items.isEmpty())
        val nextPageUrl = rule.nextPage.nextPageUrl(env, sources).bind()
        ResourceValue.List(items, nextPageUrl)
    }

    override fun afterParse(env: InterfaceEnvironment, value: ResourceValue<SearchResultItem>) {
        env.incPage()
        env.setNextPageUrl(Variables.SEARCH_URL, value)
    }
}
