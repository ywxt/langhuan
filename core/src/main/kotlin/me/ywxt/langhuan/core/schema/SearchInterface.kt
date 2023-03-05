package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.*
import com.github.michaelbull.result.coroutines.binding.binding
import io.ktor.utils.io.charsets.*
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class SearchInterface(
    private val searchRule: SearchRule,
) : ResourceInterface<SearchResultItem> {

    override fun init(env: InterfaceEnvironment) {
        env.setVariable("page", 0)
        searchRule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Result<Action, InterfaceError> =
        this.searchRule.request.buildAction(env)

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment
    ): Result<IndicateHasNext<List<SearchResultItem>>, InterfaceError> = binding {
        val items = searchRule.area.parse(sources).map { source ->
            val itemSources = ParsedSources(source)
            val title = parseField(env, itemSources, searchRule.title).andThen {
                if (it == null) {
                    Err(
                        InterfaceError.ParsingError(
                            "Cannot find field in the document by given rule(`${searchRule.title}`)."
                        )
                    )
                } else {
                    Ok(it)
                }
            }.bind()
            val infoUrl = parseField(env, itemSources, searchRule.infoUrl).andThen {
                if (it == null) {
                    Err(
                        InterfaceError.ParsingError(
                            "Cannot find field in the document by given rule(`${searchRule.infoUrl}`)."
                        )
                    )
                } else {
                    Ok(it)
                }
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
