//
// Copyright © 2021 Stream.io Inc. All rights reserved.
//

import CoreData
import Foundation

public extension _ChatClient {
    /// Creates a new `CurrentUserController` instance.
    ///
    /// - Returns: A new instance of `CurrentChatUserController`.
    ///
    func currentUserController() -> _CurrentChatUserController<ExtraData> {
        .init(client: self)
    }
}

/// `CurrentChatUserController` is a controller class which allows observing and mutating the currently logged-in
/// user of `ChatClient`.
///
/// Learn more about `CurrentChatUserController` and its usage in our [cheat sheet](https://github.com/GetStream/stream-chat-swift/wiki/Cheat-Sheet#user).
///
/// - Note: `CurrentChatUserController` is a typealias of `_CurrentChatUserController` with default extra data. If you're using
/// custom extra data, create your own typealias of `_CurrentChatUserController`.
///
/// Learn more about using custom extra data in our [cheat sheet](https://github.com/GetStream/stream-chat-swift/wiki/Cheat-Sheet#working-with-extra-data).
///
public typealias CurrentChatUserController = _CurrentChatUserController<NoExtraData>

/// `CurrentChatUserController` is a controller class which allows observing and mutating the currently logged-in
/// user of `ChatClient`.
///
/// Learn more about `CurrentChatUserController` and its usage in our [cheat sheet](https://github.com/GetStream/stream-chat-swift/wiki/Cheat-Sheet#user).
///
/// - Note: `_CurrentChatUserController` type is not meant to be used directly. If you're using default extra data, use
/// `CurrentChatUserController` typealias instead. If you're using custom extra data, create your own typealias
/// of `_CurrentChatUserController`.
///
/// Learn more about using custom extra data in our [cheat sheet](https://github.com/GetStream/stream-chat-swift/wiki/Cheat-Sheet#working-with-extra-data).
///
public class _CurrentChatUserController<ExtraData: ExtraDataTypes>: DataController, DelegateCallable, DataStoreProvider {
    /// The `ChatClient` instance this controller belongs to.
    public let client: _ChatClient<ExtraData>
    
    private let environment: Environment
    
    /// An internal backing object for all publicly available Combine publishers. We use it to simplify the way we expose
    /// publishers. Instead of creating custom `Publisher` types, we use `CurrentValueSubject` and `PassthroughSubject` internally,
    /// and expose the published values by mapping them to a read-only `AnyPublisher` type.
    @available(iOS 13, *)
    lazy var basePublishers: BasePublishers = .init(controller: self)

    /// Used for observing the current user changes in a database.
    private lazy var currentUserObserver = createUserObserver()
        .onChange { [unowned self] change in
            self.delegateCallback {
                $0.currentUserController(self, didChangeCurrentUser: change)
            }
        }
        .onFieldChange(\.unreadCount) { [unowned self] change in
            self.delegateCallback {
                $0.currentUserController(self, didChangeCurrentUserUnreadCount: change.unreadCount)
            }
        }

    /// A type-erased delegate.
    var multicastDelegate: MulticastDelegate<AnyCurrentUserControllerDelegate<ExtraData>> = .init()
    
    /// The currently logged-in user. `nil` if the connection hasn't been fully established yet, or the connection
    /// wasn't successful.
    public var currentUser: _CurrentChatUser<ExtraData.User>? {
        startObservingIfNeeded()
        return currentUserObserver.item
    }

    /// The unread messages and channels count for the current user.
    ///
    /// Returns `noUnread` if `currentUser` doesn't exist yet.
    ///
    public var unreadCount: UnreadCount {
        currentUser?.unreadCount ?? .noUnread
    }

    private lazy var chatClientUpdater = environment.chatClientUpdaterBuilder(client)
    
    /// The worker used to update the current user.
    private lazy var currentUserUpdater = environment.currentUserUpdaterBuilder(
        client.databaseContainer,
        client.apiClient
    )

    /// Creates a new `CurrentUserControllerGeneric`.
    ///
    /// - Parameters:
    ///   - client: The `Client` instance this controller belongs to.
    ///   - environment: The source of internal dependencies
    ///
    init(client: _ChatClient<ExtraData>, environment: Environment = .init()) {
        self.client = client
        self.environment = environment
    }
    
    override public func synchronize(_ completion: ((_ error: Error?) -> Void)? = nil) {
        startObservingIfNeeded()
        
        if case let .localDataFetchFailed(error) = state {
            callback { completion?(error) }
            return
        }
        
        guard let currentUserId = currentUser?.id else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }
        
        currentUserUpdater.fetchDevices(currentUserId: currentUserId) { error in
            self.state = error == nil ? .remoteDataFetched : .remoteDataFetchFailed(ClientError(with: error))
            self.callback { completion?(error) }
        }
    }
    
    private func startObservingIfNeeded() {
        guard state == .initialized else { return }
        
        do {
            try currentUserObserver.startObserving()
            state = .localDataFetched
        } catch {
            log.error("""
            Observing current user failed: \(error).\n
            Accessing `currentUser` will always return `nil`, `unreadCount` with `.noUnread`
            """)
            state = .localDataFetchFailed(ClientError(with: error))
        }
    }
}

public extension _CurrentChatUserController {
    /// Fetches the token from `tokenProvider` and prepares the current `ChatClient` variables
    /// for the new user.
    ///
    /// If the a token obtained from `tokenProvider` is for another user the
    /// database will be flushed.
    ///
    /// If `config.shouldConnectAutomatically` is set to `true` it also
    /// tries to establish a web-socket connection.
    ///
    /// If `config.shouldConnectAutomatically` is set to `false` the
    /// establishing a web-socket connection has to be done manually via `connect/disconnect`
    /// methods in `ChatConnectionController`.
    ///
    /// - Parameter completion: The completion to be called when the operation is completed.
    func reloadUserIfNeeded(completion: ((Error?) -> Void)? = nil) {
        chatClientUpdater.reloadUserIfNeeded { error in
            self.callback {
                completion?(error)
            }
        }
    }

    /// Updates the current user data.
    ///
    /// By default all data is `nil`, and it won't be updated unless a value is provided.
    ///
    /// - Parameters:
    ///   - name: Optionally provide a new name to be updated.
    ///   - imageURL: Optionally provide a new image to be updated.
    ///   - userExtraData: Optionally provide new user extra data to be updated.
    ///   - completion: Called when user is successfuly updated, or with error.
    func updateUserData(
        name: String? = nil,
        imageURL: URL? = nil,
        userExtraData: ExtraData.User? = nil,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let currentUserId = currentUser?.id else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }
        
        currentUserUpdater.updateUserData(
            currentUserId: currentUserId,
            name: name,
            imageURL: imageURL,
            userExtraData: userExtraData
        ) { error in
            self.callback {
                completion?(error)
            }
        }
    }
    
    /// Registers a device to the current user.
    /// `setUser` must be called before calling this.
    /// - Parameters:
    ///   - token: Device token, obtained via `didRegisterForRemoteNotificationsWithDeviceToken` function in `AppDelegate`.
    ///   - completion: Called when device is successfully registered, or with error.
    func addDevice(token: Data, completion: ((Error?) -> Void)? = nil) {
        guard let currentUserId = currentUser?.id else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }
        
        currentUserUpdater.addDevice(token: token, currentUserId: currentUserId) { error in
            self.callback {
                completion?(error)
            }
        }
    }
    
    /// Removes a registered device from the current user.
    /// `setUser` must be called before calling this.
    /// - Parameters:
    ///   - id: Device id to be removed. You can obtain registered devices via `currentUser.devices`.
    ///   If `currentUser.devices` is not up-to-date, please make an `synchronize` call.
    ///   - completion: Called when device is successfully deregistered, or with error.
    func removeDevice(id: String, completion: ((Error?) -> Void)? = nil) {
        guard let currentUserId = currentUser?.id else {
            completion?(ClientError.CurrentUserDoesNotExist())
            return
        }
        
        currentUserUpdater.removeDevice(id: id, currentUserId: currentUserId) { error in
            self.callback {
                completion?(error)
            }
        }
    }
}

// MARK: - Environment

extension _CurrentChatUserController {
    struct Environment {
        var currentUserObserverBuilder: (
            _ context: NSManagedObjectContext,
            _ fetchRequest: NSFetchRequest<CurrentUserDTO>,
            _ itemCreator: @escaping (CurrentUserDTO) -> _CurrentChatUser<ExtraData.User>,
            _ fetchedResultsControllerType: NSFetchedResultsController<CurrentUserDTO>.Type
        ) -> EntityDatabaseObserver<_CurrentChatUser<ExtraData.User>, CurrentUserDTO> = EntityDatabaseObserver.init
        
        var currentUserUpdaterBuilder = CurrentUserUpdater<ExtraData>.init

        var chatClientUpdaterBuilder = ChatClientUpdater<ExtraData>.init
    }
}

// MARK: - Private

private extension EntityChange where Item == UnreadCount {
    var unreadCount: UnreadCount {
        switch self {
        case let .create(count):
            return count
        case let .update(count):
            return count
        case .remove:
            return .noUnread
        }
    }
}

private extension _CurrentChatUserController {
    func createUserObserver() -> EntityDatabaseObserver<_CurrentChatUser<ExtraData.User>, CurrentUserDTO> {
        environment.currentUserObserverBuilder(
            client.databaseContainer.viewContext,
            CurrentUserDTO.defaultFetchRequest,
            { $0.asModel() },
            NSFetchedResultsController<CurrentUserDTO>.self
        )
    }
}

// MARK: - Delegates

/// `CurrentChatUserController` uses this protocol to communicate changes to its delegate.
///
/// This protocol can be used only when no custom extra data are specified.
/// If you're using custom extra data types, please use `_CurrentChatUserControllerDelegate` instead.
///
public protocol CurrentChatUserControllerDelegate: AnyObject {
    /// The controller observed a change in the `UnreadCount`.
    func currentUserController(_ controller: CurrentChatUserController, didChangeCurrentUserUnreadCount: UnreadCount)
    
    /// The controller observed a change in the `CurrentChatUser` entity.
    func currentUserController(_ controller: CurrentChatUserController, didChangeCurrentUser: EntityChange<CurrentChatUser>)
}

public extension CurrentChatUserControllerDelegate {
    func currentUserController(_ controller: CurrentChatUserController, didChangeCurrentUserUnreadCount: UnreadCount) {}
    
    func currentUserController(_ controller: CurrentChatUserController, didChangeCurrentUser: EntityChange<CurrentChatUser>) {}
}

/// `CurrentChatUserController` uses this protocol to communicate changes to its delegate.
///
/// If you're **not** using custom extra data types, you can use a convenience version of this protocol
/// named `CurrentChatUserControllerDelegate`, which hides the generic types, and make the usage easier.
///
public protocol _CurrentChatUserControllerDelegate: AnyObject {
    associatedtype ExtraData: ExtraDataTypes
    
    /// The controller observed a change in the `UnreadCount`.
    func currentUserController(_ controller: _CurrentChatUserController<ExtraData>, didChangeCurrentUserUnreadCount: UnreadCount)
    
    /// The controller observed a change in the `CurrentUser` entity.
    func currentUserController(
        _ controller: _CurrentChatUserController<ExtraData>,
        didChangeCurrentUser: EntityChange<_CurrentChatUser<ExtraData.User>>
    )
}

public extension _CurrentChatUserControllerDelegate {
    func currentUserController(
        _ controller: _CurrentChatUserController<ExtraData>,
        didChangeCurrentUserUnreadCount: UnreadCount
    ) {}
    
    func currentUserController(
        _ controller: _CurrentChatUserController<ExtraData>,
        didChangeCurrentUser: EntityChange<_CurrentChatUser<ExtraData.User>>
    ) {}
}

final class AnyCurrentUserControllerDelegate<ExtraData: ExtraDataTypes>: _CurrentChatUserControllerDelegate {
    weak var wrappedDelegate: AnyObject?
    
    private var _controllerDidChangeCurrentUserUnreadCount: (
        _CurrentChatUserController<ExtraData>,
        UnreadCount
    ) -> Void
    
    private var _controllerDidChangeCurrentUser: (
        _CurrentChatUserController<ExtraData>,
        EntityChange<_CurrentChatUser<ExtraData.User>>
    ) -> Void
    
    init(
        wrappedDelegate: AnyObject?,
        controllerDidChangeCurrentUserUnreadCount: @escaping (
            _CurrentChatUserController<ExtraData>,
            UnreadCount
        ) -> Void,
        controllerDidChangeCurrentUser: @escaping (
            _CurrentChatUserController<ExtraData>,
            EntityChange<_CurrentChatUser<ExtraData.User>>
        ) -> Void
    ) {
        self.wrappedDelegate = wrappedDelegate
        _controllerDidChangeCurrentUserUnreadCount = controllerDidChangeCurrentUserUnreadCount
        _controllerDidChangeCurrentUser = controllerDidChangeCurrentUser
    }
    
    func currentUserController(
        _ controller: _CurrentChatUserController<ExtraData>,
        didChangeCurrentUserUnreadCount unreadCount: UnreadCount
    ) {
        _controllerDidChangeCurrentUserUnreadCount(controller, unreadCount)
    }
    
    func currentUserController(
        _ controller: _CurrentChatUserController<ExtraData>,
        didChangeCurrentUser user: EntityChange<_CurrentChatUser<ExtraData.User>>
    ) {
        _controllerDidChangeCurrentUser(controller, user)
    }
}

extension AnyCurrentUserControllerDelegate {
    convenience init<Delegate: _CurrentChatUserControllerDelegate>(_ delegate: Delegate) where Delegate.ExtraData == ExtraData {
        self.init(
            wrappedDelegate: delegate,
            controllerDidChangeCurrentUserUnreadCount: { [weak delegate] in
                delegate?.currentUserController($0, didChangeCurrentUserUnreadCount: $1)
            },
            controllerDidChangeCurrentUser: { [weak delegate] in
                delegate?.currentUserController($0, didChangeCurrentUser: $1)
            }
        )
    }
}

extension AnyCurrentUserControllerDelegate where ExtraData == NoExtraData {
    convenience init(_ delegate: CurrentChatUserControllerDelegate?) {
        self.init(
            wrappedDelegate: delegate,
            controllerDidChangeCurrentUserUnreadCount: { [weak delegate] in
                delegate?.currentUserController($0, didChangeCurrentUserUnreadCount: $1)
            },
            controllerDidChangeCurrentUser: { [weak delegate] in
                delegate?.currentUserController($0, didChangeCurrentUser: $1)
            }
        )
    }
}
 
public extension _CurrentChatUserController {
    /// Sets the provided object as a delegate of this controller.
    ///
    /// - Note: If you don't use custom extra data types, you can set the delegate directly using `controller.delegate = self`.
    /// Due to the current limits of Swift and the way it handles protocols with associated types, it's required to use this
    /// method to set the delegate, if you're using custom extra data types.
    ///
    /// - Parameter delegate: The object used as a delegate. It's referenced weakly, so you need to keep the object
    /// alive if you want keep receiving updates.
    func setDelegate<Delegate: _CurrentChatUserControllerDelegate>(_ delegate: Delegate?) where Delegate.ExtraData == ExtraData {
        multicastDelegate.mainDelegate = delegate.flatMap(AnyCurrentUserControllerDelegate.init)
    }
}

public extension CurrentChatUserController {
    /// Set the delegate of `CurrentUserController` to observe the changes in the system.
    ///
    /// - Note: The delegate can be set directly only if you're **not** using custom extra data types. Due to the current
    /// limits of Swift and the way it handles protocols with associated types, it's required to use `setDelegate` method
    /// instead to set the delegate, if you're using custom extra data types.
    var delegate: CurrentChatUserControllerDelegate? {
        get { multicastDelegate.mainDelegate?.wrappedDelegate as? CurrentChatUserControllerDelegate }
        set { multicastDelegate.mainDelegate = AnyCurrentUserControllerDelegate(newValue) }
    }
}
