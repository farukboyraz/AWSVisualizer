import Foundation

struct AWSRegion: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    static let all: [AWSRegion] = [
        AWSRegion(code: "us-east-1", name: "US East (N. Virginia)"),
        AWSRegion(code: "us-east-2", name: "US East (Ohio)"),
        AWSRegion(code: "us-west-1", name: "US West (N. California)"),
        AWSRegion(code: "us-west-2", name: "US West (Oregon)"),
        AWSRegion(code: "af-south-1", name: "Africa (Cape Town)"),
        AWSRegion(code: "ap-east-1", name: "Asia Pacific (Hong Kong)"),
        AWSRegion(code: "ap-south-1", name: "Asia Pacific (Mumbai)"),
        AWSRegion(code: "ap-south-2", name: "Asia Pacific (Hyderabad)"),
        AWSRegion(code: "ap-southeast-1", name: "Asia Pacific (Singapore)"),
        AWSRegion(code: "ap-southeast-2", name: "Asia Pacific (Sydney)"),
        AWSRegion(code: "ap-southeast-3", name: "Asia Pacific (Jakarta)"),
        AWSRegion(code: "ap-southeast-4", name: "Asia Pacific (Melbourne)"),
        AWSRegion(code: "ap-northeast-1", name: "Asia Pacific (Tokyo)"),
        AWSRegion(code: "ap-northeast-2", name: "Asia Pacific (Seoul)"),
        AWSRegion(code: "ap-northeast-3", name: "Asia Pacific (Osaka)"),
        AWSRegion(code: "ca-central-1", name: "Canada (Central)"),
        AWSRegion(code: "ca-west-1", name: "Canada West (Calgary)"),
        AWSRegion(code: "eu-central-1", name: "Europe (Frankfurt)"),
        AWSRegion(code: "eu-central-2", name: "Europe (Zurich)"),
        AWSRegion(code: "eu-west-1", name: "Europe (Ireland)"),
        AWSRegion(code: "eu-west-2", name: "Europe (London)"),
        AWSRegion(code: "eu-west-3", name: "Europe (Paris)"),
        AWSRegion(code: "eu-north-1", name: "Europe (Stockholm)"),
        AWSRegion(code: "eu-south-1", name: "Europe (Milan)"),
        AWSRegion(code: "eu-south-2", name: "Europe (Spain)"),
        AWSRegion(code: "il-central-1", name: "Israel (Tel Aviv)"),
        AWSRegion(code: "me-central-1", name: "Middle East (UAE)"),
        AWSRegion(code: "me-south-1", name: "Middle East (Bahrain)"),
        AWSRegion(code: "sa-east-1", name: "South America (São Paulo)"),
    ]

    static func displayName(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }
}
