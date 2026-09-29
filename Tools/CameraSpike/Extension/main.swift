import CoreMediaIO
import Foundation

// Entry point of the spike's Camera Extension: publish the provider and serve CoreMediaIO clients forever.
let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
