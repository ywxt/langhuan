package me.ywxt.langhuan.core.schema

import kotlin.collections.List

sealed class ResourceValue<T> {
    data class Item<T>(val value: T) : ResourceValue<T>()

    data class List<T>(val list: kotlin.collections.List<T>) : ResourceValue<T>()

}

