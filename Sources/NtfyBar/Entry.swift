import AppKit

@main
enum Main {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        // Dev-only: `ntfy-bar --snapshot out.png [--dark] [--state file.json] [--empty]`
        if let i = args.firstIndex(of: "--snapshot") {
            Snapshot.run(args: Array(args[(i + 1)...]))
            return
        }
        NtfyBarApp.main()
    }
}
