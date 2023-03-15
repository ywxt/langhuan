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
