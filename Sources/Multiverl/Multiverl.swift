// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

private class SendableWrapper: NSObject, @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) {
        self.value = value
    }
}

public protocol MultiverlType: Sendable {
    var id: AnyHashable { get }
    var uri: String { get }
    var ver: UInt { get }
    func link(_ parameter: Any?) async throws -> Any?
}

public enum MultiverlError: Error {
    case notFound
}

public extension MultiverlType {
    func link(_ parameter: Any?) async throws -> Any? {
        throw MultiverlError.notFound
    }
}

private class MultiverlPath: NSObject, @unchecked Sendable {
    var superPath: MultiverlPath?
    var subPaths: [String: MultiverlPath] = [:]
    var vers: [MultiverlType] = []
    
    let path: String
    
    init(_ path: String) {
        self.path = path
    }
}

private actor MultiverlActor {
    private var path = MultiverlPath("")
    
    private var blockIds: Set<AnyHashable> = Set()

    func updateBlockIds(_ blockIds: Set<AnyHashable>) {
        self.blockIds = blockIds
    }
    
    func isBlocked(_ id: AnyHashable) -> Bool {
        return blockIds.contains { element in
            id == element
        }
    }
    
    func register(_ vers: [MultiverlType]) {
        vers.forEach { ver in
            do {
                let path = try getPath(ver.uri, register: true)
                if !path.vers.contains(where: { element in
                    ver.id == element.id
                }) {
                    path.vers.append(ver)
                    path.vers.sort { $0.ver < $1.ver }
                }
            } catch {
            }
        }
    }
    
    func unregister(_ vers: [MultiverlType]) {
        vers.forEach { ver in
            do {
                try getPath(ver.uri).vers.removeAll { element in
                    ver.id == element.id
                }
            } catch {
            }
        }
    }
    
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
    
    private func getPath(_ uri: String, register: Bool = false) throws -> MultiverlPath {
        var paths = uri.components(separatedBy: ".")
        paths.removeAll { path in
            path == ""
        }
        guard paths.count > 0 else {
            throw MultiverlError.notFound
        }
        var nextPath: MultiverlPath = path
        try paths.forEach { path in
            nextPath = try getSubPath(path, upperPath: nextPath, register: register)
        }
        return nextPath
    }
    
    func getVer(_ uri: String, lastVer: MultiverlType? = nil, lastPath: MultiverlPath? = nil) throws -> (MultiverlType, MultiverlPath) {
        guard let lastPath = lastPath else {
            let path = try getPath(uri)
            if let ver = path.vers.last {
                return (ver, path)
            }
            return try getVer(uri, lastVer: nil, lastPath: path)
        }
        if let lastVer = lastVer {
            let index = lastPath.vers.firstIndex { ver in
                lastVer.id == ver.id
            } ?? 0
            if index > 0 {
                return (lastPath.vers[index - 1], lastPath)
            }
        }
        guard  let superPath = lastPath.superPath else {
            throw MultiverlError.notFound
        }
        var nextPath = superPath.subPaths["*"]
        if nextPath == nil {
            nextPath = superPath
        }
        let nextVer = nextPath?.vers.last
        return try getVer(uri, lastVer: nextVer, lastPath: nextPath)
    }
}

public class Multiverl: NSObject, @unchecked Sendable {
    private let actor = MultiverlActor()
    
    public var blockIds: Set<AnyHashable> = Set() {
        didSet {
            Task {
                await actor.updateBlockIds(blockIds)
            }
        }
    }
    
    public func register(_ vers: [MultiverlType]) {
        Task {
            await actor.register(vers)
        }
    }
    
    public func register(_ vers: [MultiverlType]) async {
        await actor.register(vers)
    }
    
    public func unregister(_ vers: [MultiverlType]) {
        Task {
            await actor.unregister(vers)
        }
    }
    
    public func unregister(_ vers: [MultiverlType]) async {
        await actor.unregister(vers)
    }
    
    @discardableResult
    public func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil) async throws -> Any? {
        return try await link(uri, parameter: parameter, ver: ver, id: id, lastVer: nil, lastPath: nil)
    }
    
    private func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil, lastVer: MultiverlType? = nil, lastPath: MultiverlPath? = nil) async throws -> Any? {
        let (nextVer, nextPath) = try await actor.getVer(uri, lastVer: lastVer, lastPath: lastPath)
        let isBlocked = await actor.isBlocked(nextVer.id)
        if !isBlocked {
            if let id = id {
                if nextVer.id == id {
                    return try await nextVer.link(parameter)
                }
            } else {
                if nextVer.ver <= ver {
                    do {
                        let result = try await nextVer.link(parameter)
                        return result
                    } catch MultiverlError.notFound {} catch {
                        throw error
                    }
                }
            }
        }
        return try await link(uri, parameter: parameter, ver: ver, id: id, lastVer: nextVer, lastPath: nextPath)
    }
    
    public func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil, result: ((_ result: Any?, _ error: Error?) -> Void)? = nil) {
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

public extension Multiverl {
    static let main = Multiverl()
    
    static func register(_ ver: MultiverlType) {
        main.register([ver])
    }
    
    static func register(_ ver: MultiverlType) async {
        await main.register([ver])
    }
    
    static func register(_ vers: [MultiverlType]) {
        main.register(vers)
    }
    
    static func register(_ vers: [MultiverlType]) async {
        await main.register(vers)
    }
    
    static func unregister(_ ver: MultiverlType) {
        main.unregister([ver])
    }
    
    static func unregister(_ ver: MultiverlType) async {
        await main.unregister([ver])
    }
    
    static func unregister(_ vers: [MultiverlType]) {
        main.unregister(vers)
    }
    
    static func unregister(_ vers: [MultiverlType]) async {
        await main.unregister(vers)
    }
    
    static func link(_ uri: String, parameter: Any? = nil, ver: UInt = UInt.max, id: AnyHashable? = nil) async throws -> Any? {
        return try await main.link(uri, parameter: parameter, ver: ver, id: id)
    }
}

public typealias MultiverlHandler = (_ parameter: Any?) async throws -> Any?

private class MultiverlTypeWrapper: NSObject, MultiverlType, @unchecked Sendable {
    public var id: AnyHashable
    public var uri: String
    public var ver: UInt
    private var handler: MultiverlHandler
    
    init(id: AnyHashable, uri: String, ver: UInt, handler: @escaping MultiverlHandler) {
        self.id = id
        self.uri = uri
        self.ver = ver
        self.handler = handler
    }
    
    func link(_ parameter: Any?) async throws -> Any? {
        return try await handler(parameter)
    }
}

public extension Multiverl {
    @discardableResult
    func register(_ uri: String, handler: @escaping MultiverlHandler, ver: UInt = 0, id: AnyHashable = UUID().uuidString) -> MultiverlType {
        let wrapper = MultiverlTypeWrapper(id: id, uri: uri, ver: ver, handler: handler)
        register([wrapper])
        return wrapper
    }
    
    @discardableResult
    func register(_ uri: String, handler: @escaping MultiverlHandler, ver: UInt = 0, id: AnyHashable = UUID().uuidString) async -> MultiverlType {
        let wrapper = MultiverlTypeWrapper(id: id, uri: uri, ver: ver, handler: handler)
        await register([wrapper])
        return wrapper
    }
}
