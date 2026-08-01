// Release-only native Android SBOM integration. Keep this isolated from normal
// application builds while pinning the exact reviewed generator artifact.
import org.cyclonedx.gradle.CyclonedxPlugin
import org.cyclonedx.gradle.CyclonedxDirectTask
import org.cyclonedx.model.Component

initscript {
    repositories {
        gradlePluginPortal()
    }
    dependencies {
        classpath("org.cyclonedx.bom:org.cyclonedx.bom.gradle.plugin:3.2.4")
    }
}

rootProject {
    val mobilePubspec = rootDir.resolve("../pubspec.yaml")
    if (rootDir.name == "android" && mobilePubspec.isFile) {
        val releaseFlavor = System.getenv("PAKPERK_ANDROID_SBOM_FLAVOR") ?: "prod"
        require(releaseFlavor in setOf("dev", "staging", "prod")) {
            "PAKPERK_ANDROID_SBOM_FLAVOR must be dev, staging, or prod"
        }
        val mobileVersion =
            mobilePubspec
            .useLines { lines ->
                lines.firstOrNull { it.startsWith("version:") }
            }?.substringAfter(":")
            ?.trim()
            ?.substringBefore("+")
            ?: error("mobile/pubspec.yaml has no version")
        require(Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(mobileVersion)) {
            "mobile/pubspec.yaml has an unsafe application version"
        }
        apply<CyclonedxPlugin>()
        allprojects {
            tasks.withType<CyclonedxDirectTask>().configureEach {
                if (project.path == ":app") {
                    includeConfigs.set(listOf("${releaseFlavor}ReleaseRuntimeClasspath"))
                    includeBuildEnvironment.set(false)
                    includeMetadataResolution.set(true)
                    includeBuildSystem.set(false)
                    includeLicenseText.set(false)
                    componentGroup.set("app.pakperk")
                    componentName.set("pakperk-android")
                    componentVersion.set(mobileVersion)
                    projectType.set(Component.Type.APPLICATION)
                    xmlOutput.unsetConvention()
                } else {
                    enabled = false
                }
            }
        }
    }
}
