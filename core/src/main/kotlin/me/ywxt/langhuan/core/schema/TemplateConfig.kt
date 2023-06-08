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
import io.ktor.utils.io.charsets.*
import korlibs.template.AutoEscapeMode
import korlibs.template.Filter
import korlibs.template.Template
import korlibs.template.TemplateConfig
import korlibs.template.dynamic.DynamicType
import korlibs.template.dynamic.JvmObjectMapper2
import korlibs.template.dynamic.invokeSuspend
import me.ywxt.langhuan.core.ConfigParsingError
import me.ywxt.langhuan.core.utils.catchException
import java.lang.reflect.Modifier
import java.net.URLDecoder
import java.net.URLEncoder
import kotlin.reflect.KClass

val urlEncodingFilter = Filter("url_encode") {
    val charset =
        args.firstOrNull()?.run { charset(toDynamicString()) } ?: this.context.scope.get(Variables.CHARSET)
            ?.run { this as Charset }
            ?: Charsets.UTF_8

    URLEncoder.encode(subject.toDynamicString(), charset)
}

val urlDecodingFilter = Filter("url_decode") {
    val charset =
        args.firstOrNull()?.run { charset(toDynamicString()) } ?: this.context.scope.get(Variables.CHARSET)
            ?.run { this as Charset }
            ?: Charsets.UTF_8
    URLDecoder.decode(subject.toDynamicString(), charset)
}

val intFilter = Filter("int") {
    subject.toDynamicInt()
}

val substringFilter = Filter("substring") {
    val start = args.firstOrNull()?.toDynamicInt() ?: 0
    val end = args.getOrNull(1)?.toDynamicInt() ?: subject.toDynamicString().length
    subject.toDynamicString().substring(start, end)
}

open class LanghuanObjectMapper : JvmObjectMapper2() {
    override suspend fun invokeAsync(type: KClass<Any>, instance: Any?, key: String, args: List<Any?>): Any? {
        if (instance is DynamicType<*>) return instance.dynamicShape.callMethod(instance, key, args)
        val method = type.classInfo.methodsByName[key] ?: return null
        if (Modifier.isPublic(method.modifiers) && !method.canAccess(instance)) {
            method.isAccessible = true
        }
        return method.invokeSuspend(instance, args)
    }

    override suspend fun set(instance: Any, key: Any?, value: Any?) {
        if (instance is DynamicType<*>) return instance.dynamicShape.setProp(instance, key, value)
        val prop = instance::class.classInfo.propByName[key] ?: return
        val setter = prop.setter
        val field = prop.field
        when {
            setter != null -> {
                if (Modifier.isPublic(setter.modifiers) && !setter.canAccess(instance)) {
                    setter.isAccessible = true
                }
                setter.invoke(instance, value)
            }

            field != null -> {
                if (Modifier.isPublic(field.modifiers) && !field.canAccess(instance)) {
                    field.isAccessible = true
                }
                field.set(instance, value)
            }
        }
    }

    override suspend fun get(instance: Any, key: Any?): Any? {
        if (instance is DynamicType<*>) return instance.dynamicShape.getProp(instance, key)
        val prop = instance::class.classInfo.propByName[key] ?: return null
        val getter = prop.getter
        val field = prop.field
        return when {
            getter != null -> {
                if (Modifier.isPublic(getter.modifiers) && !getter.canAccess(instance)) {
                    getter.isAccessible = true
                }
                getter.invoke(instance)
            }

            field != null -> {
                if (Modifier.isPublic(field.modifiers) && !field.canAccess(instance)) {
                    field.isAccessible = true
                }
                field.get(instance)
            }

            else -> null
        }
    }
}

val objectMapper = LanghuanObjectMapper()

internal suspend fun Template.render(context: Context<*>) = this.invoke(context, objectMapper)

internal suspend fun Template.render(context: ResultContext<*>) = this.invoke(context, objectMapper)

val templateConfig =
    TemplateConfig(
        extraFilters = listOf(urlDecodingFilter, urlEncodingFilter, intFilter, substringFilter),
        autoEscapeMode = AutoEscapeMode.RAW,
    )

@Suppress("FunctionName")
suspend fun TemplateWithConfig(str: String): Either<ConfigParsingError, Template> =
    catchException { Template(str, templateConfig) }
        .mapLeft { ConfigParsingError(it.stackTraceToString()) }
