// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingRecord",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MeetingRecord", targets: ["MeetingRecordApp"]),
        .executable(name: "MeetingAIValidate", targets: ["MeetingAIValidate"]),
        .library(name: "MeetingCore", targets: ["MeetingCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.7.85")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CZlib"),
        .target(name: "MeetingCore", dependencies: ["CSQLite"], resources: [.copy("Resources/Localization.json")]),
        .target(name: "MeetingAudio", dependencies: ["MeetingCore"]),
        .target(name: "MeetingCloud", dependencies: [
            "MeetingCore", "CZlib",
            .product(name: "AWSTranscribeStreaming", package: "aws-sdk-swift"),
            .product(name: "AWSTranscribe", package: "aws-sdk-swift"),
            .product(name: "AWSS3", package: "aws-sdk-swift"),
            .product(name: "AWSSTS", package: "aws-sdk-swift")
        ]),
        .executableTarget(name: "MeetingRecordApp", dependencies: ["MeetingCore", "MeetingAudio", "MeetingCloud"]),
        .executableTarget(name: "MeetingAIValidate", dependencies: ["MeetingCore", "MeetingCloud", "MeetingAudio"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
        .testTarget(name: "MeetingAudioTests", dependencies: ["MeetingAudio"]),
        .testTarget(name: "MeetingCloudTests", dependencies: ["MeetingCloud"])
    ],
    swiftLanguageModes: [.v5]
)
