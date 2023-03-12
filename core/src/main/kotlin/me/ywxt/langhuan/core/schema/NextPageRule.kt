package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import me.ywxt.langhuan.core.InterfaceError

data class NextPageRule(
    val hasNextPage: ParsableField,
    val nextPageUrl: ParsableField? = null,
)

internal suspend fun NextPageRule.nextPageUrl(
    env: InterfaceEnvironment,
    sources: ParsedSources,
): Either<InterfaceError.ParsingError, String?> = either {
    if (hasNextPage.parseField(env, sources).bind().toBoolean()) {
        nextPageUrl?.parseNonNullableFiled(env, sources)?.bind()
    } else {
        null
    }
}
