package me.ywxt.langhuan.core.schema

import arrow.core.Either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

interface ResourceInterface<T> {
    fun init(env: InterfaceEnvironment)
    suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action>
    suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment
    ): Either<InterfaceError, ResourceValue<T>>
}
