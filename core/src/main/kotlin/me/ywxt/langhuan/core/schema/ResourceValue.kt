package me.ywxt.langhuan.core.schema

sealed class ResourceValue<T> {
    data class Item<T>(val value: T) : ResourceValue<T>()

    data class List<T>(val list: kotlin.collections.List<T>, val hasNextPage: Boolean) : ResourceValue<T>()
}
