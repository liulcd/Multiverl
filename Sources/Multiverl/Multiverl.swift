// The Swift Programming Language
// https://docs.swift.org/swift-book
//
//  Multiverl.swift
//  Multiverl - A Multi-Version Routing Library for Swift
//
//  A powerful and flexible routing system that supports:
//  - URI-based routing with dot-separated path components
//  - Version-aware handler resolution with fallback support
//  - Wildcard path matching using "*" for flexible routing
//  - Thread-safe operations using Swift's actor model
//  - Blocking mechanism to temporarily disable specific handlers
//
//  Copyright © 2024. All rights reserved.
//

import Foundation

// MARK: - Sendable Wrapper

/// A thread-safe wrapper for non-Sendable values.
/// Used internally to pass arbitrary values across async boundaries safely.
private class SendableWrapper: NSObject, @unchecked Sendable {
    /// The wrapped value, can be any type including nil
    let value: Any?
    
    /// Initialize with a value to wrap
    /// - Parameter value: The value to wrap for cross-boundary transfer
    init(_ value: Any?) {
        self.value = value
    }
}

// MARK: - MultiverlType Protocol

/// The core protocol that all Multiverl handlers must conform to.
/// Defines the interface for registerable route handlers with versioning support.
///
/// Example implementation:
/// ```swift
/// struct MyHandler: MultiverlType {
///     var id: AnyHashable { "my-handler-id" }
///     var uri: String { "app.feature.action" }
///     var ver: UInt { 1 }
///
///     func link(_ parameter: Any?) async throws -> Any? {
///         // Handle the route and return result
///         return "Success"
///     }
/// }
/// ```
public protocol MultiverlType: Sendable {
    /// Unique identifier for this handler instance.
    /// Used to prevent duplicate registrations and for unregistering.
    var id: AnyHashable { get }
    
    /// The URI path this handler responds to.
    /// Uses dot-separated components (e.g., "app.user.profile").
    var uri: String { get }
    
    /// Version number for this handler.
    /// Higher versions take priority when resolving routes.
    /// Use 0 for default/fallback handlers.
    var ver: UInt { get }
    
    /// Handle the route request with the given parameter.
    /// - Parameter parameter: Optional parameter passed from the caller
    /// - Returns: The result of handling the route (can be any type)
    /// - Throws: `MultiverlError.notFound` to delegate to lower version handlers
    func link(_ parameter: Any?) async throws -> Any?
}

// MARK: - MultiverlError

/// Errors that can occur during Multiverl routing operations.
public enum MultiverlError: Error {
    /// No matching handler was found for the requested URI.
    /// Also used by handlers to signal delegation to fallback handlers.
    case notFound
}

// MARK: - MultiverlType Default Implementation

/// Default implementation for MultiverlType protocol.
/// Provides a fallback behavior that throws `.notFound`.
public extension MultiverlType {
    /// Default implementation that throws `.notFound`.
    /// Override this method to provide actual handling logic.
    func link(_ parameter: Any?) async throws -> Any? {
        throw MultiverlError.notFound
    }
}

// MARK: - MultiverlPath (Internal)

/// Internal class representing a node in the URI path tree.
/// Used to organize handlers in a hierarchical structure for efficient lookup.
private class MultiverlPath: NSObject, @unchecked Sendable {
    /// Reference to the parent path node (for traversing up the tree)
    var superPath: MultiverlPath?
    
    /// Dictionary mapping path component names to child nodes
    var subPaths: [String: MultiverlPath] = [:]
    
    /// Array of handlers registered at this path, sorted by version (ascending)
    var vers: [MultiverlType] = []
    
    /// The name of this path component
    let path: String
    
    /// Initialize a path node with a component name
    /// - Parameter path: The name of this path component
    init(_ path: String) {
        self.path = path
    }
}

// MARK: - MultiverlActor (Internal)

/// Actor responsible for thread-safe management of the routing tree.
/// All route registration, unregistration, and resolution operations
/// are performed through this actor to ensure data consistency.
private actor MultiverlActor {
    
    // MARK: Properties
    
    /// Root node of the path tree
    private var path = MultiverlPath("")
    
    /// Set of handler IDs that are currently blocked
    private var blockIds: Set<AnyHashable> = Set()
    
    // MARK: Block Management
    
    /// Update the set of blocked handler IDs.
    /// Blocked handlers will be skipped during route resolution.
    /// - Parameter blockIds: New set of IDs to block
    func updateBlockIds(_ blockIds: Set<AnyHashable>) {
        self.blockIds = blockIds
    }
    
    /// Check if a handler ID is currently blocked.
    /// - Parameter id: The handler ID to check
    /// - Returns: true if the handler is blocked, false otherwise
    func isBlocked(_ id: AnyHashable) -> Bool {
        return blockIds.contains { element in
            id == element
        }
    }
    
    // MARK: Registration
    
    /// Register multiple handlers with the routing system.
    /// Handlers are organized by URI and sorted by version number.
    /// - Parameter vers: Array of handlers to register
    func register(_ vers: [MultiverlType]) {
        vers.forEach { ver in
            do {
                // Get or create the path node for this URI
                let path = try getPath(ver.uri, register: true)
                
                // Only add if not already registered (by ID)
                if !path.vers.contains(where: { element in
                    ver.id == element.id
                }) {
                    path.vers.append(ver)
                    // Keep handlers sorted by version (ascending, so higher versions are at the end)
                    path.vers.sort { $0.ver < $1.ver }
                }
            } catch {
                // Ignore invalid URIs silently
            }
        }
    }
    
    /// Unregister multiple handlers from the routing system.
    /// - Parameter vers: Array of handlers to unregister
    func unregister(_ vers: [MultiverlType]) {
        vers.forEach { ver in
            do {
                // Find the path and remove the handler by ID
                try getPath(ver.uri).vers.removeAll { element in
                    ver.id == element.id
                }
            } catch {
                // Ignore if path doesn't exist
            }
        }
    }
    
    // MARK: Path Resolution
    
    /// Get or create a child path node.
    /// - Parameters:
    ///   - path: The name of the child path component
    ///   - upperPath: The parent path node
    ///   - register: If true, create the path if it doesn't exist
    /// - Returns: The child path node
    /// - Throws: `MultiverlError.notFound` if path doesn't exist and register is false
    private func getSubPath(_ path: String, upperPath: MultiverlPath, register: Bool = false) throws -> MultiverlPath {
        if let subPath = upperPath.subPaths[path] {
            return subPath
        }
        if register {
            let subPath = MultiverlPath(path)
            upperPath.subPaths[path] = subPath
            subPath.superPath = upperPath
            return subPath
        }
        throw MultiverlError.notFound
    }
    
    /// Resolve a URI string to its corresponding path node.
    /// - Parameters:
    ///   - uri: Dot-separated URI string (e.g., "app.user.profile")
    ///   - register: If true, create intermediate paths as needed
    /// - Returns: The path node corresponding to the URI
    /// - Throws: `MultiverlError.notFound` if URI is empty or path doesn't exist
    private func getPath(_ uri: String, register: Bool = false) throws -> MultiverlPath {
        // Split URI into components
        var paths = uri.components(separatedBy: ".")
        paths.removeAll { path in
            path == ""
        }
        
        // Require at least one valid path component
        guard paths.count > 0 else {
            throw MultiverlError.notFound
        }
        
        // Traverse the tree to find/create the target path
        var nextPath: MultiverlPath = path
        try paths.forEach { path in
            nextPath = try getSubPath(path, upperPath: nextPath, register: register)
        }
        return nextPath
    }
    
    // MARK: Version Resolution
    
    /// Find the next available handler for a URI.
    /// Implements version-aware resolution with fallback support:
    /// 1. Returns the highest version handler at the exact path
    /// 2. Falls back to wildcard (*) paths if available
    /// 3. Traverses up the tree looking for fallback handlers
    ///
    /// - Parameters:
    ///   - uri: The target URI string
    ///   - lastVer: The last handler that was tried (for fallback resolution)
    ///   - lastPath: The last path that was tried (for tree traversal)
    /// - Returns: Tuple of (handler, path) for the resolved handler
    /// - Throws: `MultiverlError.notFound` if no handler is available
    func getVer(_ uri: String, lastVer: MultiverlType? = nil, lastPath: MultiverlPath? = nil) throws -> (MultiverlType, MultiverlPath) {
        // First call: start from the exact path
        guard let lastPath = lastPath else {
            let path = try getPath(uri)
            if let ver = path.vers.last {
                return (ver, path)
            }
            // No handlers at this path, try fallback
            return try getVer(uri, lastVer: nil, lastPath: path)
        }
        
        // Try lower version at current path
        if let lastVer = lastVer {
            let index = lastPath.vers.firstIndex { ver in
                lastVer.id == ver.id
            } ?? 0
            if index > 0 {
                return (lastPath.vers[index - 1], lastPath)
            }
        }
        
        // No more versions at current path, try parent
        guard let superPath = lastPath.superPath else {
            throw MultiverlError.notFound
        }
        
        // Check for wildcard handler first, then parent path
        var nextPath = superPath.subPaths["*"]
        if nextPath == nil {
            nextPath = superPath
        }
        let nextVer = nextPath?.vers.last
        return try getVer(uri, lastVer: nextVer, lastPath: nextPath)
    }
}

// MARK: - Multiverl Main Class

/// The main Multiverl router class.
/// Provides a high-level API for registering handlers and resolving routes.
///
/// Multiverl supports both instance-based and static (singleton) usage:
///
/// **Instance-based usage:**
/// ```swift
/// let router = Multiverl()
/// await router.register("app.action", handler: { _ in "Result" })
/// let result = try await router.link("app.action")
/// ```
///
/// **Singleton usage:**
/// ```swift
/// await Multiverl.register("app.action", handler: { _ in "Result" })
/// let result = try await Multiverl.link("app.action")
/// ```
public class Multiverl: NSObject, @unchecked Sendable {
    
    // MARK: Properties
    
    /// Internal actor for thread-safe operations
    private let actor = MultiverlActor()
    
    /// Set of handler IDs to block.
    /// Blocked handlers are skipped during route resolution.
    /// Changes are propagated to the internal actor asynchronously.
    ///
    /// Example:
    /// ```swift
    /// router.blockIds = ["handler-1", "handler-2"]
    /// // handler-1 and handler-2 will be skipped when linking
    /// ```
    public var blockIds: Set<AnyHashable> = Set() {
        didSet {
            Task {
                await actor.updateBlockIds(blockIds)
            }
        }
    }
    
    // MARK: Registration Methods
    
    /// Register multiple handlers with the router (fire-and-forget).
    /// - Parameter vers: Array of handlers conforming to MultiverlType
    public func register(_ vers: [MultiverlType]) {
        Task {
            await actor.register(vers)
        }
    }
    
    /// Register multiple handlers with the router (async).
    /// - Parameter vers: Array of handlers conforming to MultiverlType
    public func register(_ vers: [MultiverlType]) async {
        await actor.register(vers)
    }
    
    /// Unregister multiple handlers from the router (fire-and-forget).
    /// - Parameter vers: Array of handlers to remove
    public func unregister(_ vers: [MultiverlType]) {
        Task {
            await actor.unregister(vers)
        }
    }
    
    /// Unregister multiple handlers from the router (async).
    /// - Parameter vers: Array of handlers to remove
    public func unregister(_ vers: [MultiverlType]) async {
        await actor.unregister(vers)
    }
    
    // MARK: Linking Methods
    
    /// Route a request to the appropriate handler.
    ///
    /// The routing algorithm:
    /// 1. Find handlers registered at the exact URI path
    /// 2. Select the highest version handler that doesn't exceed `ver`
    /// 3. If handler throws `.notFound`, try lower versions
    /// 4. If no match at exact path, check wildcard (*) handlers
    /// 5. Continue up the path tree looking for fallback handlers
    ///
    /// - Parameters:
    ///   - uri: Dot-separated URI path (e.g., "app.user.profile")
    ///   - parameter: Optional parameter to pass to the handler
    ///   - ver: Maximum version to consider (default: UInt.max for latest)
    ///   - id: Specific handler ID to target (bypasses version matching)
    /// - Returns: The result from the matched handler
    /// - Throws: `MultiverlError.notFound` if no handler matches
    @discardableResult
    public func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil) async throws -> Any? {
        return try await link(uri, parameter: parameter, ver: ver, id: id, lastVer: nil, lastPath: nil)
    }
    
    /// Internal recursive implementation of route resolution.
    /// Handles version matching, blocking, and fallback traversal.
    private func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil, lastVer: MultiverlType? = nil, lastPath: MultiverlPath? = nil) async throws -> Any? {
        // Get the next candidate handler
        let (nextVer, nextPath) = try await actor.getVer(uri, lastVer: lastVer, lastPath: lastPath)
        
        // Check if this handler is blocked
        let isBlocked = await actor.isBlocked(nextVer.id)
        
        if !isBlocked {
            if let id = id {
                // ID-based matching: only match specific handler
                if nextVer.id == id {
                    return try await nextVer.link(parameter)
                }
            } else {
                // Version-based matching: match if version is within limit
                if nextVer.ver <= ver {
                    do {
                        let result = try await nextVer.link(parameter)
                        return result
                    } catch MultiverlError.notFound {
                        // Handler declined, continue to fallback
                    } catch {
                        // Re-throw other errors
                        throw error
                    }
                }
            }
        }
        
        // Try next handler (lower version or fallback)
        return try await link(uri, parameter: parameter, ver: ver, id: id, lastVer: nextVer, lastPath: nextPath)
    }
    
    // MARK: Callback-Based Linking
    
    /// Route a request with callback-based result handling.
    /// Useful for integration with non-async code.
    ///
    /// - Parameters:
    ///   - uri: Dot-separated URI path
    ///   - parameter: Optional parameter to pass to the handler
    ///   - ver: Maximum version to consider
    ///   - id: Specific handler ID to target
    ///   - result: Callback with result or error
    public func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil, result: ((_ result: Any?, _ error: Error?) -> Void)? = nil) {
        // Wrap values for safe transfer across async boundary
        // Wrap values for safe transfer across async boundary
        let parameter = SendableWrapper(parameter)
        let id = SendableWrapper(id)
        let result = SendableWrapper(result)
        
        Task {
            let result = result.value as? ((_ result: Any?, _ error: Error?) -> Void)
            do {
                let a = try await link(uri, parameter: parameter.value, ver: ver, id: id.value as? AnyHashable)
                result?(a, nil)
            } catch {
                result?(nil, error)
            }
        }
    }
}

// MARK: - Static Convenience Methods

/// Extension providing static access to a shared Multiverl instance.
/// This enables a simple, global routing pattern without managing instances.
public extension Multiverl {
    
    /// The shared singleton instance of Multiverl.
    /// Use this for simple, application-wide routing.
    static let main = Multiverl()
    
    /// Register a single handler with the shared router.
    /// - Parameter ver: Handler conforming to MultiverlType
    static func register(_ ver: MultiverlType) {
        main.register([ver])
    }
    
    /// Register a single handler with the shared router (async).
    /// - Parameter ver: Handler conforming to MultiverlType
    static func register(_ ver: MultiverlType) async {
        await main.register([ver])
    }
    
    /// Register multiple handlers with the shared router.
    /// - Parameter vers: Array of handlers
    static func register(_ vers: [MultiverlType]) {
        main.register(vers)
    }
    
    /// Register multiple handlers with the shared router (async).
    /// - Parameter vers: Array of handlers
    static func register(_ vers: [MultiverlType]) async {
        await main.register(vers)
    }
    
    /// Unregister a single handler from the shared router.
    /// - Parameter ver: Handler to remove
    static func unregister(_ ver: MultiverlType) {
        main.unregister([ver])
    }
    
    /// Unregister a single handler from the shared router (async).
    /// - Parameter ver: Handler to remove
    static func unregister(_ ver: MultiverlType) async {
        await main.unregister([ver])
    }
    
    /// Unregister multiple handlers from the shared router.
    /// - Parameter vers: Array of handlers to remove
    static func unregister(_ vers: [MultiverlType]) {
        main.unregister(vers)
    }
    
    /// Unregister multiple handlers from the shared router (async).
    /// - Parameter vers: Array of handlers to remove
    static func unregister(_ vers: [MultiverlType]) async {
        await main.unregister(vers)
    }
    
    /// Route a request using the shared router.
    /// - Parameters:
    ///   - uri: Dot-separated URI path
    ///   - parameter: Optional parameter to pass to the handler
    ///   - ver: Maximum version to consider
    ///   - id: Specific handler ID to target
    /// - Returns: The result from the matched handler
    static func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil) async throws -> Any? {
        return try await main.link(uri, parameter: parameter, ver: ver, id: id)
    }
}

// MARK: - Handler Type Alias

/// Type alias for closure-based handlers.
/// Handlers receive an optional parameter and return an optional result.
public typealias MultiverlHandler = (_ parameter: Any?) async throws -> Any?

// MARK: - MultiverlTypeWrapper (Internal)

/// Internal wrapper class that converts closure-based handlers into MultiverlType.
/// Enables the convenience `register(uri:handler:)` API.
private class MultiverlTypeWrapper: NSObject, MultiverlType, @unchecked Sendable {
    /// Unique identifier for this handler
    public var id: AnyHashable
    
    /// The URI path this handler responds to
    public var uri: String
    
    /// Version number for this handler
    public var ver: UInt
    
    /// The closure that handles the route
    private var handler: MultiverlHandler
    
    /// Initialize a wrapper with handler details.
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - uri: URI path to register
    ///   - ver: Version number
    ///   - handler: Closure to handle requests
    init(id: AnyHashable, uri: String, ver: UInt, handler: @escaping MultiverlHandler) {
        self.id = id
        self.uri = uri
        self.ver = ver
        self.handler = handler
    }
    
    /// Invoke the wrapped handler.
    func link(_ parameter: Any?) async throws -> Any? {
        return try await handler(parameter)
    }
}

// MARK: - Closure-Based Registration

/// Extension providing convenient closure-based handler registration.
public extension Multiverl {
    
    /// Register a handler using a closure (fire-and-forget).
    ///
    /// Example:
    /// ```swift
    /// router.register("app.greeting") { name in
    ///     return "Hello, \(name ?? "World")!"
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - uri: Dot-separated URI path
    ///   - handler: Closure to handle requests
    ///   - ver: Version number (default: 0)
    ///   - id: Unique identifier (default: auto-generated UUID)
    /// - Returns: The registered handler (useful for later unregistration)
    @discardableResult
    func register(_ uri: String, handler: @escaping MultiverlHandler, ver: UInt = 0, id: AnyHashable = UUID().uuidString) -> MultiverlType {
        let wrapper = MultiverlTypeWrapper(id: id, uri: uri, ver: ver, handler: handler)
        register([wrapper])
        return wrapper
    }
    
    /// Register a handler using a closure (async).
    ///
    /// - Parameters:
    ///   - uri: Dot-separated URI path
    ///   - handler: Closure to handle requests
    ///   - ver: Version number (default: 0)
    ///   - id: Unique identifier (default: auto-generated UUID)
    /// - Returns: The registered handler (useful for later unregistration)
    @discardableResult
    func register(_ uri: String, handler: @escaping MultiverlHandler, ver: UInt = 0, id: AnyHashable = UUID().uuidString) async -> MultiverlType {
        let wrapper = MultiverlTypeWrapper(id: id, uri: uri, ver: ver, handler: handler)
        await register([wrapper])
        return wrapper
    }
}
