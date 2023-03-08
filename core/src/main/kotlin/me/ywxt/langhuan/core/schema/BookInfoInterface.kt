package me.ywxt.langhuan.core.schema

import arrow.core.Either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class BookInfoInterface(private val rule: BookInfoRule): ResourceInterface<BookInfo> {
    override fun init(env: InterfaceEnvironment) {
        TODO("Not yet implemented")
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> {
        TODO("Not yet implemented")
    }

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment,
    ): Either<InterfaceError, IndicateHasNext<ResourceValue<BookInfo>>> {
        TODO("Not yet implemented")
    }
}
