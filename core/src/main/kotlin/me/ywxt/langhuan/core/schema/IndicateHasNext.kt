package me.ywxt.langhuan.core.schema

sealed interface IndicateHasNext<T>

data class NextIndication<T>(val value: T, val hasNext: Boolean) : IndicateHasNext<T>

data class CurrentIndication<T>(val value: T?) : IndicateHasNext<T>
