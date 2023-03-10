package me.ywxt.langhuan.core.schema

import io.ktor.utils.io.charsets.*
import me.ywxt.langhuan.core.InterfaceError
import me.ywxt.langhuan.core.utils.catchException

class InterfaceEnvironment(
    private val parentEnvironment: InterfaceEnvironment?,
) {
    private val variables: MutableMap<String, Any> = mutableMapOf()
    private val headers: MutableMap<String, String> = mutableMapOf()

    fun getVariable(name: String): Any? = variables[name] ?: parentEnvironment?.getVariable(name)

    fun setVariable(name: String, value: Any) {
        variables[name] = value
    }

    fun getAllVariables(): Map<String, Any> = ScopeMap(parentEnvironment?.variables, variables)

    fun getHeader(name: String): String? = headers[name] ?: parentEnvironment?.getHeader(name)
    fun setHeader(name: String, value: String) {
        headers[name] = value
    }

    fun getAllHeaders(): Map<String, String> = ScopeMap(parentEnvironment?.headers, headers)
}

fun InterfaceEnvironment.initPage() {
    setVariable(Variables.PAGE, 0)
}

fun InterfaceEnvironment.incPage() {
    setVariable(Variables.PAGE, getVariable(Variables.PAGE) as Int + 1)
}

inline fun <reified T> InterfaceEnvironment.setNextPageUrl(name: String, value: ResourceValue<T>) {
    if (value is ResourceValue.List<T>) {
        value.nextPageUrl?.let { setVariable(name, it) }
    }
}

fun InterfaceEnvironment.getCharset() = catchException {
    getVariable(Variables.CHARSET) as Charset
}.mapLeft { InterfaceError.InvalidVariable(Variables.CHARSET) }
