package me.ywxt.langhuan.core.schema

import arrow.core.Either
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

interface ResourceInterface<T> {
    fun init(env: InterfaceEnvironment)
    suspend fun buildAction(env: InterfaceEnvironment): Either<InterfaceError, Action>
    suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment
    ): Either<InterfaceError, ResourceValue<T>>
}

internal suspend fun parseField(
    env: InterfaceEnvironment,
    sources: ParsedSources,
    field: ParsableField,
): Either<InterfaceError.ParsingError, String?> = Either.catch {
    val parser = field.parser
    val template = field.template
    val environment = InterfaceEnvironment(env)
    parser.parse(sources).firstOrNull()?.let {
        environment.setVariable("result", it)
        val fieldVariables = environment.getAllVariables()
        template(fieldVariables)
    }
}.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }

internal suspend fun parseList(
    env: InterfaceEnvironment,
    sources: ParsedSources,
    field: ParsableField,
): Either<InterfaceError.ParsingError, List<String>> = Either.catch {
    val parser = field.parser
    val template = field.template
    val environment = InterfaceEnvironment(env)
    parser.parse(sources).map {
        environment.setVariable("result", it)
        val fieldVariables = environment.getAllVariables()
        template(fieldVariables)
    }
}.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }

internal fun needNonNullableField(field: String?, fieldRule: ParsableField) = if (field == null) {
    Either.Left(
        InterfaceError.ParsingError(
            "Cannot find field in the document by given rule(`$fieldRule`)."
        )
    )
} else {
    Either.Right(field)
}
