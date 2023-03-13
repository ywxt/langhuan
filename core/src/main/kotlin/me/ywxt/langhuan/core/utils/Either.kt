package me.ywxt.langhuan.core.utils

import arrow.core.Either
import arrow.core.left
import arrow.core.nonFatalOrThrow
import arrow.core.right

@Suppress("TooGenericExceptionCaught")
inline fun <R> catchException(f: () -> R): Either<Exception, R> =
    try {
        f().right()
    } catch (t: Exception) {
        (t.nonFatalOrThrow() as Exception).left()
    }
