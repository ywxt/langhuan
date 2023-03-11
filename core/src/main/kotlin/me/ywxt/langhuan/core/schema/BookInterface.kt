package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

class BookInterface(private val rule: BookInfoRule) : ResourceInterface<BookInfo> {
    override fun init(env: InterfaceEnvironment) {
        rule.request.headers?.forEach { (name, value) -> env.setHeader(name, value) }
    }

    override suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action> =
        rule.request.buildAction(env)

    override suspend fun process(
        env: InterfaceEnvironment,
        sources: ParsedSources,
    ): Either<InterfaceError, ResourceValue<BookInfo>> = either {
        val title = rule.title.parseNonNullableFiled(env, sources).bind()
        val contentsUrl =
            rule.contentsUrl.parseNonNullableFiled(env, sources).bind()
        val author = rule.author?.parseField(env, sources)?.bind()
        val description = rule.description?.parseField(env, sources)?.bind()
        val extraTags = rule.extraTags?.parseList(env, sources)?.bind()?.toList()
        ResourceValue.Item(BookInfo(title, contentsUrl, author, description, extraTags))
    }
}
