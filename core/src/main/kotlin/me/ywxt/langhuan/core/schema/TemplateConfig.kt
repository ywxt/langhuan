package me.ywxt.langhuan.core.schema

import com.soywiz.korte.AutoEscapeMode
import com.soywiz.korte.Filter
import com.soywiz.korte.TemplateConfig
import io.ktor.utils.io.charsets.*
import java.net.URLDecoder
import java.net.URLEncoder

val urlEncodingFilter = Filter("url_encode") {

    val charset =
        args.firstOrNull()?.run { charset(toDynamicString()) } ?: this.context.scope.get("charset")
            ?.run { this as Charset }
            ?: Charsets.UTF_8

    URLEncoder.encode(subject.toDynamicString(), charset)
}

val urlDecodingFilter = Filter("url_decode") {
    val charset =
        args.firstOrNull()?.run { charset(toDynamicString()) } ?: this.context.scope.get("charset")
            ?.run { this as Charset }
            ?: Charsets.UTF_8
    URLDecoder.decode(subject.toDynamicString(), charset)
}

val intFilter = Filter("int") {
    subject.toDynamicInt()
}

val templateConfig =
    TemplateConfig(
        extraFilters = listOf(urlDecodingFilter, urlEncodingFilter, intFilter),
        autoEscapeMode = AutoEscapeMode.RAW
    )
