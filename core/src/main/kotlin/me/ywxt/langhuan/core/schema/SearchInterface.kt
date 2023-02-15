package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.*
import io.ktor.utils.io.charsets.*
import kotlinx.coroutines.flow.Flow
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class SearchInterface(private val searchRule: SearchRule, parentEnvironment: InterfaceEnvironment) :
    ResourceInterface<SearchResultItem> {
    override val environment: InterfaceEnvironment

    init {
        environment = InterfaceEnvironment(parentEnvironment).apply {
            setVariable("page", 0)
        }
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
    ): Result<IndicateHasNext<Flow<SearchResultItem>>, InterfaceError> {
        TODO("Not yet implemented")
    }
}
