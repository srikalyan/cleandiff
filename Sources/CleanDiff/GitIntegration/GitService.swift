import Foundation

/// Git integration service for diff tool and merge tool operations
actor GitService {

    enum GitError: LocalizedError {
        case notARepository
        case commandFailed(String)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .notARepository:
                return "Not a git repository"
            case .commandFailed(let message):
                return "Git command failed: \(message)"
            case .parseError(let message):
                return "Failed to parse git output: \(message)"
            }
        }
    }

    /// Check if a directory is a git repository
    func isGitRepository(at path: URL) async throws -> Bool {
        do {
            _ = try await runGit(["rev-parse", "--git-dir"], in: path)
            return true
        } catch {
            return false
        }
    }

    /// Get the root of the git repository
    func repositoryRoot(at path: URL) async throws -> URL {
        let output = try await runGit(["rev-parse", "--show-toplevel"], in: path)
        return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Get modified files in the working tree
    func modifiedFiles(at path: URL) async throws -> [FileStatus] {
        let output = try await runGit(["status", "--porcelain", "-z"], in: path)
        return parseStatusOutput(output)
    }

    /// Get the diff between two refs for a file
    func diff(file: String, from: String = "HEAD", to: String? = nil, at path: URL) async throws -> String {
        var args = ["diff", from]
        if let to = to {
            args.append(to)
        }
        args.append("--")
        args.append(file)

        return try await runGit(args, in: path)
    }

    /// Get file content at a specific ref
    func showFile(_ file: String, at ref: String, in path: URL) async throws -> String {
        try await runGit(["show", "\(ref):\(file)"], in: path)
    }

    /// Get merge base between two commits
    func mergeBase(_ ref1: String, _ ref2: String, at path: URL) async throws -> String {
        let output = try await runGit(["merge-base", ref1, ref2], in: path)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stage a file
    func stageFile(_ file: String, at path: URL) async throws {
        _ = try await runGit(["add", file], in: path)
    }

    /// Unstage a file
    func unstageFile(_ file: String, at path: URL) async throws {
        _ = try await runGit(["reset", "HEAD", "--", file], in: path)
    }

    /// Get conflicted files during a merge
    func conflictedFiles(at path: URL) async throws -> [String] {
        let output = try await runGit(["diff", "--name-only", "--diff-filter=U"], in: path)
        return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    // MARK: - Private

    private func runGit(_ args: [String], in directory: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw GitError.commandFailed(errorOutput)
        }

        return output
    }

    private func parseStatusOutput(_ output: String) -> [FileStatus] {
        var files: [FileStatus] = []
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true)

        for entry in entries {
            guard entry.count >= 3 else { continue }

            let statusIndex = entry.index(entry.startIndex, offsetBy: 2)
            let statusCode = String(entry[..<statusIndex])
            let path = String(entry[entry.index(after: statusIndex)...])

            if let status = FileStatus.Status(rawValue: statusCode.trimmingCharacters(in: .whitespaces)) {
                files.append(FileStatus(path: path, status: status))
            }
        }

        return files
    }
}

struct FileStatus: Identifiable {
    let id = UUID()
    let path: String
    let status: Status

    enum Status: String {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "?"
        case ignored = "!"
        case unmerged = "U"

        var description: String {
            switch self {
            case .modified: return "Modified"
            case .added: return "Added"
            case .deleted: return "Deleted"
            case .renamed: return "Renamed"
            case .copied: return "Copied"
            case .untracked: return "Untracked"
            case .ignored: return "Ignored"
            case .unmerged: return "Conflict"
            }
        }
    }
}

// MARK: - Command Line Interface

/// CLI support for git difftool and mergetool integration
enum CLIHandler {

    struct Arguments {
        var leftPath: String?
        var rightPath: String?
        var basePath: String?
        var outputPath: String?
        var isDirectory: Bool = false
    }

    static func parseArguments(_ args: [String]) -> Arguments {
        var result = Arguments()
        var i = 1  // Skip program name

        while i < args.count {
            let arg = args[i]

            switch arg {
            case "-o", "--output":
                if i + 1 < args.count {
                    result.outputPath = args[i + 1]
                    i += 1
                }
            case "-d", "--directory":
                result.isDirectory = true
            default:
                // Positional arguments: left, right, [base]
                if result.leftPath == nil {
                    result.leftPath = arg
                } else if result.rightPath == nil {
                    result.rightPath = arg
                } else if result.basePath == nil {
                    result.basePath = arg
                }
            }
            i += 1
        }

        return result
    }

    static func printUsage() {
        print("""
        Usage: cleandiff [options] <left> <right> [base]

        Options:
          -o, --output <file>    Output file for merge result
          -d, --directory        Compare directories

        Git difftool configuration:
          git config --global diff.tool cleandiff
          git config --global difftool.cleandiff.cmd 'cleandiff "$LOCAL" "$REMOTE"'

        Git mergetool configuration:
          git config --global merge.tool cleandiff
          git config --global mergetool.cleandiff.cmd 'cleandiff "$LOCAL" "$BASE" "$REMOTE" -o "$MERGED"'
          git config --global mergetool.cleandiff.trustExitCode true
        """)
    }
}
