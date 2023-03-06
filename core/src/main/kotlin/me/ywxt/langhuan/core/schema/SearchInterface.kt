package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import arrow.core.flatMap
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class SearchInterface(
    private val searchRule: SearchRule,
) : ResourceInterface<SearchResultItem> {

    override fun init(env: InterfaceEnvironment) {
        env.setVariable("page", 0)
        searchRule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        this.searchRule.request.buildAction(env)

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment,
    ): Either<InterfaceError, IndicateHasNext<List<SearchResultItem>>> = either {
        val items = searchRule.area.parse(sources).map { source ->
            val itemSources = ParsedSources(source)
            val title = parseField(env, itemSources, searchRule.title).flatMap {
                needNonNullableField(it, searchRule.title)
            }.bind()
            val infoUrl = parseField(env, itemSources, searchRule.infoUrl).flatMap {
                needNonNullableField(it, searchRule.infoUrl)
            }.bind()
            val author = searchRule.author?.let { parseField(env, itemSources, it).bind() }
            val description = searchRule.description?.let { parseField(env, itemSources, it).bind() }
            val extraTags = searchRule.extraTags?.let { parseList(env, itemSources, it).bind() }
            SearchResultItem(title, infoUrl, author, description, extraTags)
        }
        env.setVariable("page", env.getVariable("page") as Int + 1)
        NextIndication(items, false)
    }
}
