#if os(macOS)
import WorkBenchKit

@main enum AssistantCLI {
  static func main() async { await AssistantCommand.main() }
}
#endif
