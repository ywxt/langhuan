package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import arrow.core.flatMap
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
        val items = rule.area.parse(sources).map { source ->
            val itemSources = ParsedSources(source)
            val title = parseField(env, itemSources, rule.title).flatMap {
                needNonNullableField(it, rule.title)
            }.bind()
            val infoUrl = parseField(env, itemSources, rule.infoUrl).flatMap {
                needNonNullableField(it, rule.infoUrl)
            }.bind()
            val author = rule.author?.let { parseField(env, itemSources, it).bind() }
            val description = rule.description?.let { parseField(env, itemSources, it).bind() }
            val extraTags = rule.extraTags?.let { parseList(env, itemSources, it).bind() }
            SearchResultItem(title, infoUrl, author, description, extraTags)
        }
        val hasNextPage = if (rule.hasNextPage == null) {
            items.isEmpty()
        } else {
            parseField(env, sources, rule.hasNextPage).flatMap { needNonNullableField(it, rule.hasNextPage) }.map {
                it.toBoolean()
            }.bind()
        }
        env.setVariable("page", env.getVariable("page") as Int + 1)
        ResourceValue.List(items, hasNextPage)
    }
}
