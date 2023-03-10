package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.flatMap
import com.soywiz.korte.Template
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.utils.catchException

data class ParsableField(val parser: Parser, val template: Template) {
    override fun toString(): String = "ParsableField(parser=$parser, template=${template.template})"
}

internal suspend fun ParsableField.parseField(
    env: InterfaceEnvironment,
    sources: ParsedSources,
): Either<InterfaceError.ParsingError, String?> = catchException {
    val parser = this.parser
    val template = this.template
    val environment = InterfaceEnvironment(env)
    parser.parse(sources).firstOrNull()?.let {
        environment.setVariable("result", it)
        val fieldVariables = environment.getAllVariables()
        template(fieldVariables)
    }
}.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }

internal suspend fun ParsableField.parseList(
    env: InterfaceEnvironment,
    sources: ParsedSources,
): Either<InterfaceError.ParsingError, List<String>> = catchException {
    val parser = this.parser
    val template = this.template
    val environment = InterfaceEnvironment(env)
    parser.parse(sources).asIterable().map {
        environment.setVariable("result", it)
        val fieldVariables = environment.getAllVariables()
        template(fieldVariables)
    }
}.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }

internal fun ParsableField.needNonNullableField(field: String?) = if (field == null) {
    Either.Left(
        InterfaceError.ParsingError(
            "Cannot find field in the document by given rule(`$this`)."
        )
    )
} else {
    Either.Right(field)
}

internal suspend fun ParsableField.parseNonNullableFiled(
    env: InterfaceEnvironment,
    sources: ParsedSources,
): Either<InterfaceError.ParsingError, String> = parseField(env, sources).flatMap { needNonNullableField(it) }
