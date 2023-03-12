package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import arrow.core.right
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.PanicException
import me.ywxt.langhuan.core.http.HttpClient

class ResourceClient<T>(
    private val resInterface: ResourceInterface<T>,
    private val client: HttpClient,
) {
    suspend fun fetch(env: InterfaceEnvironment): Flow<Either<InterfaceError, T>> {
        resInterface.init(env)
        return when (val either = requestAndParse(env)) {
            is Either.Left -> flowOf(either)
            is Either.Right -> when (val value = either.value) {
                is ResourceValue.Item -> flowOf(value.value.right())
                is ResourceValue.List -> nextPages(env, value)
            }
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
    ): Flow<Either<InterfaceError, T>> = flow {
        var value = list
        value.list.forEach { emit(it.right()) }
        while (value.nextPageUrl != null) {
            val result = requestAndParse(env)
            if (result is Either.Left) {
                emit(result)
                break
            }
            val listValue = (result as Either.Right).value
            if (listValue is ResourceValue.List) {
                value = listValue
            } else {
                PanicException.throwString("The parsing result must be a List. \n Result: `$result`")
            }
            value.list.forEach { emit(it.right()) }
        }
    }
}
