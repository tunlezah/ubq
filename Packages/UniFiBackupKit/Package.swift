// swift-tools-version: 6.0
// UniFiBackupKit — a UI-free Swift package that decrypts, unpacks, and
// parses UniFi Network Controller `.unf` backup files.
//
// See /ARCHITECTURE.md and /DECISIONS.md in the repo root for rationale.

import PackageDescription

let package = Package(
    name: "UniFiBackupKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "UniFiBackupKit",
            targets: ["UniFiBackupKit"]
        )
    ],
    targets: [
        // Public façade. Consumers import this.
        .target(
            name: "UniFiBackupKit",
            dependencies: [
                "UnfCrypto",
                "TolerantZip",
                "Gunzip",
                "UniFiBSON",
                "BackupStream",
                "UniFiModel",
                "Diagnostics",
                "Redaction",
                "Export",
            ]
        ),

        // AES-128-CBC NoPadding wrapper around CommonCrypto.
        .target(name: "UnfCrypto", dependencies: ["Diagnostics"]),

        // Streaming ZIP reader tolerant of malformed EOCD and data descriptors.
        .target(name: "TolerantZip", dependencies: ["Diagnostics"]),

        // Thin Compression.framework wrapper for gzip streams.
        .target(name: "Gunzip", dependencies: ["Diagnostics"]),

        // Minimal read-only BSON decoder (no third-party deps).
        .target(name: "UniFiBSON", dependencies: ["Diagnostics"]),

        // Walks the concatenated BSON stream and yields (collection, document) pairs.
        .target(name: "BackupStream", dependencies: ["UniFiBSON", "Diagnostics"]),

        // Strongly-typed domain model with opaque fallback for unknown collections.
        .target(name: "UniFiModel", dependencies: ["UniFiBSON", "BackupStream", "Diagnostics"]),

        // Diagnostics: errors, warnings, info notes.
        .target(name: "Diagnostics"),

        // Secret field registry + masking for export.
        .target(name: "Redaction", dependencies: ["UniFiBSON", "UniFiModel"]),

        // Export layer: text / JSON / Markdown with LLM-preset bias.
        .target(name: "Export", dependencies: ["UniFiModel", "UniFiBSON", "Redaction"]),

        // Tests.
        .testTarget(name: "UnfCryptoTests", dependencies: ["UnfCrypto"]),
        .testTarget(name: "TolerantZipTests", dependencies: ["TolerantZip"]),
        .testTarget(name: "UniFiBSONTests", dependencies: ["UniFiBSON"]),
        .testTarget(name: "BackupStreamTests", dependencies: ["BackupStream"]),
        .testTarget(name: "ModelTests", dependencies: ["UniFiModel"]),
        .testTarget(name: "RedactionTests", dependencies: ["Redaction", "Export"]),
        .testTarget(name: "ExportTests", dependencies: ["Export", "UniFiModel"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["UniFiBackupKit"],
            resources: [
                // No committed binary fixtures; synthetic .unf blobs are
                // constructed programmatically at test time. Real-world
                // corpus lives under /fixtures (gitignored) and is used
                // only by the opt-in smoke target.
            ]
        ),
    ]
)
