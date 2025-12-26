# CleanDiff

A fast, native macOS diff and merge tool built with Swift and SwiftUI.

## Features

- **Two-way file comparison** - Side-by-side diff with syntax highlighting
- **Three-way merge** - Resolve merge conflicts with visual conflict markers
- **Directory comparison** - Compare folder contents recursively
- **Git integration** - Works as `git difftool` and `git mergetool`
- **Native macOS UI** - SwiftUI-based, follows macOS design guidelines

## Installation

### From Source

```bash
git clone https://github.com/srikalyan/cleandiff.git
cd cleandiff
swift build -c release
cp .build/release/cleandiff /usr/local/bin/
```

### Homebrew (coming soon)

```bash
brew install cleandiff
```

## Usage

### Compare two files
```bash
cleandiff file1.txt file2.txt
```

### Three-way merge
```bash
cleandiff base.txt left.txt right.txt
```

### Launch GUI without files
```bash
cleandiff
```

## Git Integration

### As difftool
```bash
git config --global diff.tool cleandiff
git config --global difftool.cleandiff.cmd 'cleandiff "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false

# Use it
git difftool HEAD~1
```

### As mergetool
```bash
git config --global merge.tool cleandiff
git config --global mergetool.cleandiff.cmd 'cleandiff "$BASE" "$LOCAL" "$REMOTE" "$MERGED"'
git config --global mergetool.cleandiff.trustExitCode true

# Use it (during merge conflicts)
git mergetool
```

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ (for building from source)

## Development

```bash
# Build
swift build

# Run tests
swift test

# Run in debug mode
swift run cleandiff
```

## Architecture

CleanDiff uses a clean separation between diff algorithms and UI:

- **DiffEngine** - Myers diff algorithm implementation
- **Models** - Data structures for comparisons and results
- **Views** - SwiftUI views for different comparison modes
- **GitIntegration** - Git repository operations

See [docs/plans/](docs/plans/) for detailed design documentation.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please read the contributing guidelines before submitting PRs.
