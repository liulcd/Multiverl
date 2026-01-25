# Multiverl

A powerful and flexible multi-version routing library for Swift.

[![Swift](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2015%2B%20%7C%20macOS%2013%2B-blue.svg)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Overview

Multiverl is a URI-based routing system that supports:

- 🎯 **URI-based routing** with dot-separated path components
- 🔄 **Version-aware resolution** with automatic fallback support
- ✨ **Wildcard matching** using `*` for flexible route handling
- 🔒 **Thread-safe operations** using Swift's actor model
- 🚫 **Handler blocking** to temporarily disable specific handlers

## Installation

### Swift Package Manager

Add Multiverl to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/liulcd/multiverl.git", from: "0.1.0")
]
```

Or add it via Xcode:
1. File → Add Package Dependencies...
2. Enter the repository URL
3. Select your version requirements

## Quick Start

### Basic Usage

```swift
import Multiverl

// Register a handler using a closure
await Multiverl.register("app.greeting") { name in
    return "Hello, \(name ?? "World")!"
}

// Call the handler
let result = try await Multiverl.link("app.greeting", parameter: "Swift")
print(result as! String) // Output: Hello, Swift!
```

### Version-Based Routing

```swift
// Register multiple versions of the same route
await Multiverl.register("app.api.users", ver: 1) { _ in
    return ["format": "v1", "users": [...]]
}

await Multiverl.register("app.api.users", ver: 2) { _ in
    return ["format": "v2", "users": [...], "metadata": [...]]
}

// Get the latest version (v2)
let latest = try await Multiverl.link("app.api.users")

// Request a specific version
let v1 = try await Multiverl.link("app.api.users", ver: 1)
```

### Custom Handler Types

Implement `MultiverlType` for more control:

```swift
struct UserProfileHandler: MultiverlType {
    var id: AnyHashable { "user-profile-handler" }
    var uri: String { "app.user.profile" }
    var ver: UInt { 1 }
    
    func link(_ parameter: Any?) async throws -> Any? {
        guard let userId = parameter as? String else {
            throw MultiverlError.notFound
        }
        // Fetch and return user profile
        return UserProfile(id: userId, name: "John Doe")
    }
}

// Register the handler
await Multiverl.register(UserProfileHandler())

// Use the handler
let profile = try await Multiverl.link("app.user.profile", parameter: "user-123")
```

### Wildcard Routes

Use `*` for catch-all handling:

```swift
// Register a wildcard handler for all "app.analytics.*" routes
await Multiverl.register("app.analytics.*") { event in
    print("Analytics event: \(event ?? "unknown")")
    return nil
}

// These all match the wildcard
try await Multiverl.link("app.analytics.pageview")
try await Multiverl.link("app.analytics.click")
try await Multiverl.link("app.analytics.purchase")
```

### Instance-Based Usage

For isolated routing contexts:

```swift
let router = Multiverl()

await router.register("feature.action") { _ in
    return "Handled by custom router"
}

let result = try await router.link("feature.action")
```

### Blocking Handlers

Temporarily disable specific handlers:

```swift
let router = Multiverl()

let handler = await router.register("app.feature", id: "feature-v1") { _ in
    return "Feature enabled"
}

// Block the handler
router.blockIds = ["feature-v1"]

// This will now throw MultiverlError.notFound or use fallback
try await router.link("app.feature")

// Unblock the handler
router.blockIds = []
```

### Callback-Based API

For integration with non-async code:

```swift
Multiverl.main.link("app.action", parameter: nil) { result, error in
    if let error = error {
        print("Error: \(error)")
    } else {
        print("Result: \(result ?? "nil")")
    }
}
```

## How Version Resolution Works

1. **Exact Path Match**: Find handlers registered at the exact URI path
2. **Version Selection**: Select the highest version handler that doesn't exceed the requested `ver`
3. **Handler Execution**: Execute the handler
4. **Fallback on `.notFound`**: If handler throws `.notFound`, try lower versions
5. **Wildcard Matching**: Check for wildcard (`*`) handlers at parent paths
6. **Parent Traversal**: Continue up the path tree looking for fallback handlers

## API Reference

### MultiverlType Protocol

```swift
public protocol MultiverlType: Sendable {
    var id: AnyHashable { get }    // Unique identifier
    var uri: String { get }        // Route path (dot-separated)
    var ver: UInt { get }          // Version number
    
    func link(_ parameter: Any?) async throws -> Any?
}
```

### Multiverl Class

| Method | Description |
|--------|-------------|
| `register(_ vers:)` | Register handlers |
| `unregister(_ vers:)` | Remove handlers |
| `link(_:parameter:ver:id:)` | Route a request |
| `blockIds` | Set of IDs to block |

### Static Methods

| Method | Description |
|--------|-------------|
| `Multiverl.main` | Shared singleton instance |
| `Multiverl.register(_:)` | Register with shared instance |
| `Multiverl.unregister(_:)` | Unregister from shared instance |
| `Multiverl.link(_:parameter:ver:id:)` | Route using shared instance |

## Requirements

- Swift 6.2+
- iOS 15.0+ / macOS 13.0+

## License

Multiverl is available under the MIT license. See the [LICENSE](LICENSE) file for more info.
