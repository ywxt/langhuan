/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */
package me.ywxt.langhuan.core.parse

import arrow.core.Either
import arrow.core.raise.either
import kotlinx.coroutines.flow.*
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.getStackTrace
import me.ywxt.langhuan.core.http.HttpClient
import me.ywxt.langhuan.core.http.requestSources

interface ResourceInterface<T, A> {
    suspend fun process(args: A): Flow<Either<InterfaceError, T>>
}

suspend fun <T, A> ResourceInterface<T, A>.processSingle(args: A): Either<InterfaceError, T> =
    process(args).singleOrNull() ?: Either.Left(InterfaceError.NotSingleError(getStackTrace()))

suspend fun <T, A> ResourceInterface<T, A>.processAll(args: A): List<Either<InterfaceError, T>> = process(args).toList()

private class BreakException(val error: InterfaceError) : Exception()

suspend fun <T, A> ResourceInterface<T, A>.processTotal(args: A): Either<InterfaceError, List<T>> = try {
    Either.Right(
        process(args).fold(mutableListOf()) { acc: MutableList<T>, value: Either<InterfaceError, T> ->
            when (value) {
                is Either.Left -> throw BreakException(value.value)
                is Either.Right -> {
                    acc.add(value.value)
                    acc
                }
            }
        }
    )
} catch (e: BreakException) {
    Either.Left(e.error)
}

@Suppress("LongParameterList")
internal suspend inline fun <T, CX> processHttpList(
    schema: SchemaConfig,
    localContext: CX,
    request: RequestRule,
    http: HttpClient,
    areaRule: ParsableField,
    nextPageRule: NextPageRule,
    crossinline afterParse: suspend (Context<CX>, List<T>) -> Unit,
    crossinline nextPage: suspend (Context<CX>, url: String?) -> Unit,
    crossinline processOne: suspend (Context<CX>, ParsedSources) -> Either<InterfaceError, T>,
): Flow<Either<InterfaceError, T>> = flow {
    while (true) {
        val context = schema.toContext(localContext, request)
        val result = either {
            val action = request.buildAction(context).bind()
            val sources = http.requestSources(action).mapLeft { InterfaceError.NetworkError(it, it.stackTrace) }.bind()
            val content = areaRule.parseList(context, sources).bind().map {
                processOne(context, ParsedSources(it)).bind()
            }
            content.forEach { emit(Either.Right(it)) }
            afterParse(context, content)
            nextPageRule.nextPageUrl(context, sources).bind()
        }
        result.onLeft {
            emit(Either.Left(it))
            return@flow
        }.onRight {
            if (!it.first) {
                return@flow
            }
            nextPage(context, it.second)
        }
    }
}

internal suspend inline fun <T, CX> processHttpOne(
    schema: SchemaConfig,
    localContext: CX,
    request: RequestRule,
    http: HttpClient,
    crossinline process: suspend (Context<CX>, ParsedSources) -> Either<InterfaceError, T>,
): Flow<Either<InterfaceError, T>> {
    val result = either {
        val context = schema.toContext(localContext, request)
        val action = request.buildAction(context).bind()
        val sources = http.requestSources(action).mapLeft { InterfaceError.NetworkError(it, it.stackTrace) }.bind()
        process(context, sources).bind()
    }
    return flowOf(result)
}
