package me.ywxt.langhuan.core.schema

import com.github.michaelbull.result.*
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.http.Action

interface ResourceInterface<T> {
    fun init(env: InterfaceEnvironment)
    suspend fun buildAction(env: InterfaceEnvironment): Result<Action, InterfaceError>
    suspend fun parse(
        sources: ParsedSources,
        env: InterfaceEnvironment
    ): Result<IndicateHasNext<List<T>>, InterfaceError>
}

internal suspend fun parseField(
    env: InterfaceEnvironment,
    sources: ParsedSources,
    field: ParsableField,
): Result<String?, InterfaceError.ParsingError> = runCatching {
    val parser = field.parser
    val template = field.template
    val environment = InterfaceEnvironment(env)
    parser.parse(sources).firstOrNull()?.let {
        environment.setVariable("result", it)
        val fieldVariables = environment.getAllVariables()
        template(fieldVariables)
    }
}.mapError { InterfaceError.ParsingError(it.stackTraceToString()) }

internal suspend fun parseList(
    env: InterfaceEnvironment,
    sources: ParsedSources,
    field: ParsableField,
): Result<List<String>, InterfaceError.ParsingError> = runCatching {
    val parser = field.parser
    val template = field.template
    val environment = InterfaceEnvironment(env)
    parser.parse(sources).map {
        environment.setVariable("result", it)
        val fieldVariables = environment.getAllVariables()
        template(fieldVariables)
    }
}.mapError { InterfaceError.ParsingError(it.stackTraceToString()) }
