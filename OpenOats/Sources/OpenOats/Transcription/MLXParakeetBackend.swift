import Foundation

/// Transcription backend for the MLX-converted Parakeet TDT v3 model.
///
/// This intentionally shells out to a bundled `parakeet-mlx` helper instead of
/// trying to load MLX weights through FluidAudio/CoreML. Packaged apps include
/// the helper under `Contents/Resources/MLXParakeet/bin/parakeet-mlx`; source
/// builds may still fall back to a developer-installed `parakeet-mlx` on PATH.
final class MLXParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    static let modelID = "mlx-community/parakeet-tdt-0.6b-v3"

    let displayName = "Parakeet TDT v3 (MLX)"

    private let executableName: String
    private let modelID: String
    private var command: HelperCommand?

    init(executableName: String = "parakeet-mlx", modelID: String = MLXParakeetBackend.modelID) {
        self.executableName = executableName
        self.modelID = modelID
    }

    func checkStatus() -> BackendStatus {
        resolveCommand() == nil
            ? .needsDownload(prompt: "MLX Parakeet helper is missing. Use a packaged OpenOats build or rebuild with BUNDLE_MLX_PARAKEET=1.")
            : .ready
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let command = resolveCommand() else {
            throw MLXParakeetBackendError.executableNotFound(executableName)
        }
        self.command = command
        onProgress(1.0)
        onStatus("Using \(displayName) via \(command.displayPath)")
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String? = nil) async throws -> String {
        guard let command else {
            throw TranscriptionBackendError.notPrepared
        }
        guard !samples.isEmpty else { return "" }

        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenOats-MLXParakeet-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let audioURL = workingDirectory.appendingPathComponent("segment.wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 16_000).write(to: audioURL, options: .atomic)

        let result = try await run(
            command: command,
            arguments: [
                audioURL.path,
                "--model", modelID,
                "--output-format", "txt",
                "--output-dir", workingDirectory.path,
                "--output-template", "transcript",
                "--chunk-duration", "0",
            ],
            environment: [
                "PARAKEET_MODEL": modelID,
                "PARAKEET_OUTPUT_FORMAT": "txt",
            ]
        )

        let outputURL = workingDirectory.appendingPathComponent("transcript.txt")
        if fileManager.fileExists(atPath: outputURL.path) {
            return try String(contentsOf: outputURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveCommand() -> HelperCommand? {
        if let bundledCommand = bundledCommand() { return bundledCommand }
        return pathCommand(for: executableName)
    }

    private func bundledCommand() -> HelperCommand? {
        guard let resourcesURL = Bundle.main.resourceURL else { return nil }
        let binURL = resourcesURL
            .appendingPathComponent("MLXParakeet", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let pythonURL = binURL.appendingPathComponent("python")
        let scriptURL = binURL.appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path) else {
            return nil
        }

        // Do not execute the venv console script directly: its shebang is an
        // absolute build-time path, so it breaks after the app is moved to
        // /Applications. Running it through the bundled venv Python keeps the
        // packaged helper relocatable.
        return HelperCommand(
            executableURL: pythonURL,
            leadingArguments: [scriptURL.path],
            displayPath: scriptURL.path
        )
    }

    private func pathCommand(for executableName: String) -> HelperCommand? {
        if executableName.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: executableName) else { return nil }
            let url = URL(fileURLWithPath: executableName)
            return HelperCommand(executableURL: url, leadingArguments: [], displayPath: url.path)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchPaths = (path.split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]).reduce(into: [String]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }

        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return HelperCommand(executableURL: candidate, leadingArguments: [], displayPath: candidate.path)
            }
        }
        return nil
    }

    private func run(
        command: HelperCommand,
        arguments: [String],
        environment: [String: String]
    ) async throws -> (stdout: String, stderr: String) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = command.executableURL
            process.arguments = command.leadingArguments + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw MLXParakeetBackendError.commandFailed(status: process.terminationStatus, stderr: stderr)
            }

            return (stdout, stderr)
        }.value
    }
}

private struct HelperCommand: Sendable {
    let executableURL: URL
    let leadingArguments: [String]
    let displayPath: String
}

enum MLXParakeetBackendError: Error, Equatable {
    case executableNotFound(String)
    case commandFailed(status: Int32, stderr: String)
}
