package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import arrow.core.flatMap
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class BookInfoInterface(private val rule: BookInfoRule) : ResourceInterface<BookInfo> {
    override fun init(env: InterfaceEnvironment) {
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment,
    ): Either<InterfaceError, ResourceValue<BookInfo>> = either {
        val title = parseField(env, sources, rule.title).flatMap { needNonNullableField(it, rule.title) }.bind()
        val contentsUrl =
            parseField(env, sources, rule.contentsUrl).flatMap { needNonNullableField(it, rule.contentsUrl) }.bind()
        val author = rule.author?.let { parseField(env, sources, it).bind() }
        val description = rule.description?.let { parseField(env, sources, it).bind() }
        val extraTags = rule.extraTags?.let { parseList(env, sources, it).bind() }
        ResourceValue.Item(BookInfo(title, contentsUrl, author, description, extraTags))
    }
}
