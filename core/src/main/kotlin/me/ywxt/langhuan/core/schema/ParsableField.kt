/**
 * Copyright 2023 ywxt
 *
 * This file is part of Langhuan.
 *
 * Langhuan is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Langhuan is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */
package me.ywxt.langhuan.core.schema

import arrow.core.Either
import arrow.core.continuations.either
import arrow.core.flatMap
import korlibs.template.Template
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.config.ParsableSection
import me.ywxt.langhuan.core.utils.catchException

data class ParsableField(val parser: Parser, val template: Template) {
    override fun toString(): String = "ParsableField(parser=$parser, template=${template.template})"

    companion object {
        suspend fun fromConfig(field: ParsableSection): Either<ConfigParsingError, ParsableField> = either {
            ParsableField(
                parser = Parser(field.expression).bind(),
                template = TemplateWithConfig(field.eval).bind(),
            )
        }
    }
}

internal suspend fun ParsableField.parseField(
    context: Context<*>,
    sources: ParsedSources,
): Either<InterfaceError.ParsingError, String?> = catchException {
    val parser = this.parser
    val template = this.template
    parser.parse(sources).firstOrNull()?.let {
        val templateContext = context.toResultContext(it)
        template.render(templateContext)
    }
}.mapLeft { InterfaceError.ParsingError(it.stackTraceToString()) }

internal suspend fun ParsableField.parseList(
    context: Context<*>,
    sources: ParsedSources,
): Either<InterfaceError.ParsingError, List<String>> = catchException {
    val parser = this.parser
    val template = this.template
    parser.parse(sources).asIterable().map {
        val templateContext = context.toResultContext(it)
        template.render(templateContext)
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
    context: Context<*>,
    sources: ParsedSources,
): Either<InterfaceError.ParsingError, String> = parseField(context, sources).flatMap { needNonNullableField(it) }
