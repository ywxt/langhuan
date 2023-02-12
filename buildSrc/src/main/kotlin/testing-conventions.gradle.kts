import org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
import org.gradle.api.tasks.testing.logging.TestLogEvent.FAILED

val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")

plugins {
    id("java-conventions")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events = setOf(FAILED)
        exceptionFormat = FULL
    }
}

dependencies {
//    testImplementation("io.kotest:kotest-runner-junit5:$KOTEST_VERSION")
//    testImplementation("io.kotest:kotest-assertions-core:$KOTEST_VERSION")
    testImplementation(libs.findBundle("kotest").get())
}
