package me.ywxt.langhuan.core.schema

class InterfaceEnvironment(
    private val parentEnvironment: InterfaceEnvironment?
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
