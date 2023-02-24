package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.Result
import com.github.michaelbull.result.andThen
import com.github.michaelbull.result.coroutines.binding.binding
import com.github.michaelbull.result.map
import com.github.michaelbull.result.mapError
import com.github.michaelbull.result.runCatching
import io.ktor.utils.io.charsets.*
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class SearchInterface(
    private val searchRule: SearchRule,
) : ResourceInterface<SearchResultItem> {

    override fun init(env: InterfaceEnvironment) {
        env.setVariable("page", 0)
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Result<Action, InterfaceError> {
        val variables = env.getAllVariables()
        val url = searchRule.url(variables)
        val charset = runCatching {
            env.getVariable("charset") as Charset
        }.mapError { InterfaceError.InvalidVariable("charset") }
        var builder = charset.map {
            Action.Builder(url).charset(it)
        }
        builder = builder.map {
            val headers = env.getAllHeaders()
            it.headers(headers)
        }.map { it.method(searchRule.method) }
        return builder.andThen { it.build() }.mapError { it as InterfaceError }
    }

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment
    ): Result<IndicateHasNext<List<SearchResultItem>>, InterfaceError> = binding {
        val items = searchRule.area.parse(sources).map { source ->
            val itemSources = ParsedSources(source)
            val title = parseField(env, itemSources, searchRule.title).bind()
            val infoUrl = parseField(env, itemSources, searchRule.infoUrl).bind()
            val author = searchRule.author?.let { parseField(env, itemSources, it).bind() }
            val description = searchRule.description?.let { parseField(env, itemSources, it).bind() }
            val extraTags = searchRule.extraTags?.let { parseList(env, itemSources, it).bind() }
            SearchResultItem(title, infoUrl, author, description, extraTags)
        }
        env.setVariable("page", env.getVariable("page") as Int + 1)
        NextIndication(
            items,
            false
        )
    }
}
