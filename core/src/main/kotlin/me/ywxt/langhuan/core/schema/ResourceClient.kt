/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Lesser Public License for more details.
 *
 * You should have received a copy of the GNU General Lesser Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/lgpl-3.0.html>.
 *
 */
package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import arrow.core.right
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.Panic
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
                Panic.throwString(
                    "Internal implementation error. " +
                        "The parsing result must be a List. \n Result: `$result`"
                )
            }
            value.list.forEach { emit(it.right()) }
        }
    }
}
