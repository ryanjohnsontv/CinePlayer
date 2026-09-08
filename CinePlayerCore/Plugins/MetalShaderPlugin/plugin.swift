import PackagePlugin
import Foundation

@main
struct MetalShaderPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        // Now that the package is on swift-tools-version 6.2, use the
        // URL-based PackagePlugin API (`File.url`, `pluginWorkDirectoryURL`,
        // and the URL-taking `Command.buildCommand` case) instead of the
        // pre-6.0 Path-based one this plugin originally shipped with. The
        // mechanism is identical either way.
        let metalFiles = target.sourceFiles.filter { $0.url.pathExtension == "metal" }.map { $0.url }
        guard !metalFiles.isEmpty else { return [] }

        // Deliberately NOT named "default.metallib": when this package is
        // opened/built in Xcode itself (as opposed to plain `swift build`),
        // Xcode's own native build system independently auto-compiles any
        // target's `.metal` source files into a `default.metallib` in the
        // same resource bundle, regardless of this plugin. Using the same
        // name caused a real "Multiple commands produce default.metallib"
        // build failure under Xcode (though never under `swift build`, which
        // has no such built-in step of its own — that's why this didn't
        // surface until building via Xcode specifically). A distinct name
        // lets both of them coexist: `swift build` only has this plugin's
        // output; Xcode has both, and only this one is ever actually loaded
        // at runtime (see CineRenderer).
        let outputDir = context.pluginWorkDirectoryURL
        let metallib = outputDir.appending(path: "CinePlayerShaders.metallib")

        return [
            .buildCommand(
                displayName: "Compiling Metal shaders",
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["-sdk", "macosx", "metal", "-o", metallib.path] + metalFiles.map(\.path),
                inputFiles: metalFiles,
                outputFiles: [metallib]
            )
        ]
    }
}
