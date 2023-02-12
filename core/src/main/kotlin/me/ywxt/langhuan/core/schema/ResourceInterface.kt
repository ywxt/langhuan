package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.Result
import kotlinx.coroutines.flow.Flow
import me.ywxt.langhuan.core.LanghuanError

interface ResourceInterface<out T, out E : LanghuanError> {
    fun query(): Flow<Result<T, E>>
}
