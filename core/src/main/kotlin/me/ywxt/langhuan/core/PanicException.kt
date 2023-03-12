package me.ywxt.langhuan.core

import arrow.core.Either

class PanicException(val error: Any) : Exception(error.toString()) {
    companion object {
        fun throwString(message: String): Nothing = throw PanicException(message)
    }
}

/**
 * Returns the encapsulated value [R] if this instance represents Either.Right or
 * throws a [PanicException] if it is Either.Left.
 * **/
inline fun <reified L : Any, reified R> Either<L, R>.get(): R {
    when (this) {
        is Either.Right -> return this.value
        is Either.Left ->
            throw PanicException(this.value)
    }
}
