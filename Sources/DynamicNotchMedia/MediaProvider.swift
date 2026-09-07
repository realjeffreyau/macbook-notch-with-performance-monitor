import Foundation

@MainActor
public protocol MediaProviderDelegate: AnyObject {
    func mediaProvider(_ provider: any MediaProvider, didUpdate session: MediaSession?)
}

@MainActor
public protocol MediaProvider: AnyObject {
    var identifier: String { get }
    var status: MediaProviderStatus { get }
    var currentSession: MediaSession? { get }
    var delegate: (any MediaProviderDelegate)? { get set }

    func start()
    func stop()
    func send(_ command: MediaCommand) -> Result<Void, MediaProviderError>
}
