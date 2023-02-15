package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.Result
import kotlinx.coroutines.flow.Flow
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

interface ResourceInterface<T> {
    val environment: InterfaceEnvironment
    suspend fun buildAction(env: InterfaceEnvironment): Result<Action, InterfaceError>
    suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment
    ): Result<IndicateHasNext<Flow<T>>, InterfaceError>
}
