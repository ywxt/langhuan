open module langhuan.core {
    requires org.jsoup;
    requires kotlin.stdlib;
    requires io.ktor.client.core;
    requires io.ktor.http;
    requires io.ktor.client.cio;
    requires io.ktor.io;
    requires arrow.core.jvm;
    requires kotlinx.coroutines.core.jvm;
    requires korte.jvm;
    requires kotlinx.serialization.core;
    requires kaml.jvm;


    exports me.ywxt.langhuan.core.http;
    exports me.ywxt.langhuan.core.schema;
    exports me.ywxt.langhuan.core.utils;
    exports me.ywxt.langhuan.core.config;
    exports me.ywxt.langhuan.core;

}