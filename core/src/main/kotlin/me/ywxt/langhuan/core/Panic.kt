package me.ywxt.langhuan.core

import arrow.core.Either

class Panic(val error: Any) : Error(error.toString()) {
    companion object {
        fun throwString(message: String): Nothing = throw Panic(message)
    }
}

/**
 * Returns the encapsulated value [R] if this instance represents Either.Right or
 * throws a [Panic] if it is Either.Left.
 * **/
inline fun <reified L : Any, reified R> Either<L, R>.get(): R {
    when (this) {
        is Either.Right -> return this.value
        is Either.Left ->
            throw Panic(this.value)
    }
}
