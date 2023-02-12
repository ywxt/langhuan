package me.ywxt.langhuan.core

import com.github.michaelbull.result.Err
import com.github.michaelbull.result.Ok
import com.github.michaelbull.result.Result

class PanicException(val error: Any) : Exception(error.toString())

inline fun <reified R, reified E : Any> Result<R, E>.getOrThrow(): R {
    when (this) {
        is Ok -> return this.value
        is Err ->
            throw PanicException(this.error)
    }
}
