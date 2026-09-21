import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val signingPropertiesFile = rootProject.file("signing.properties")
val signingProperties = Properties().apply {
    if (signingPropertiesFile.isFile) {
        signingPropertiesFile.inputStream().use(::load)
    }
}

android {
    namespace = "cn.edu.cupk.portalreader"
    compileSdk = 36

    defaultConfig {
        applicationId = "cn.edu.cupk.portalreader"
        minSdk = 26
        targetSdk = 36
        versionCode = 14
        versionName = "0.4.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    signingConfigs {
        if (signingPropertiesFile.isFile) create("release") {
            storeFile = rootProject.file(signingProperties.getProperty("storeFile"))
            storePassword = signingProperties.getProperty("storePassword")
            keyAlias = signingProperties.getProperty("keyAlias")
            keyPassword = signingProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        getByName("debug") {
            buildConfigField("String", "PORTAL_ORIGIN", "\"https://eams.cupk.edu.cn\"")
            buildConfigField("boolean", "LOCAL_MOCK_ENABLED", "false")
        }
        getByName("release") {
            isMinifyEnabled = false
            buildConfigField("String", "PORTAL_ORIGIN", "\"https://eams.cupk.edu.cn\"")
            buildConfigField("boolean", "LOCAL_MOCK_ENABLED", "false")
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.09.00"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.appcompat:appcompat:1.8.0")
    implementation("androidx.webkit:webkit:1.17.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}

// AGP 9.2 built-in Kotlin currently omits its unit-test output directory from the
// Gradle Test task classpath on some Windows/non-ASCII project paths.
tasks.withType<Test>().configureEach {
    doFirst {
        val portableTestClasses = file("${System.getProperty("user.home")}/.gradle/palmacademic-test-classes")
        project.copy {
            duplicatesStrategy = DuplicatesStrategy.EXCLUDE
            from(layout.buildDirectory.dir("intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes"))
            from(layout.buildDirectory.dir("intermediates/built_in_kotlinc/debugUnitTest/compileDebugUnitTestKotlin/classes"))
            into(portableTestClasses)
        }
        classpath = classpath.plus(
            files(portableTestClasses)
        )
    }
}
