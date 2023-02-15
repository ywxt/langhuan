package me.ywxt.langhuan.core.schema

sealed interface IndicateHasNext<T>

data class NextIndication<T>(val element: T, val hasNext: Boolean) : IndicateHasNext<T>

data class CurrentIndication<T>(val element: T?) : IndicateHasNext<T>
