package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.HttpClient

class ResourceClient<T>(
    private val resInterface: ResourceInterface<T>,
    private val client: HttpClient,
) {
    suspend fun fetch(env: InterfaceEnvironment): Either<InterfaceError, Flow<T>> = either {
        resInterface.init(env)
        when (val value = requestAndParse(env).bind()) {
            is ResourceValue.Item -> flowOf(value.value)
            is ResourceValue.List -> nextPages(env, value).bind()
        }
    }

    private suspend fun requestAndParse(env: InterfaceEnvironment): Either<InterfaceError, ResourceValue<T>> = either {
        val action = resInterface.buildAction(env).bind()
        val response = client.request(action).mapLeft { InterfaceError.NetworkError(it) }.bind()
        val sources = ParsedSources(response)
        resInterface.process(env, sources).bind()
    }

    private suspend fun nextPages(
        env: InterfaceEnvironment,
        list: ResourceValue.List<T>,
    ): Either<InterfaceError, Flow<T>> = either {
        flow {
            var value = list
            value.list.forEach { emit(it) }
            while (value.nextPageUrl != null) {
                val result = requestAndParse(env).bind()
                if (result is ResourceValue.List) {
                    value = result
                } else {
                    Either.Left(InterfaceError.ParsingError("The parsing result must be a List. \n Result: `$result`"))
                        .bind<Flow<T>>()
                }
                value.list.forEach { emit(it) }
            }
        }
    }
}
