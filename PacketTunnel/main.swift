import Foundation
import NetworkExtension

// System-extension entry point: register provider classes (from Info.plist NEProviderClasses)
// and hand control to the NE runtime.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
