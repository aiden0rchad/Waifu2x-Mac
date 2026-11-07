import Foundation

// PNG-backed ICNS records also work when IconServices is unavailable on a build host.
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let records = [("icp4", "16x16"), ("ic11", "16x16@2x"),
               ("icp5", "32x32"), ("ic12", "32x32@2x"),
               ("ic07", "128x128"), ("ic13", "128x128@2x"),
               ("ic08", "256x256"), ("ic14", "256x256@2x"),
               ("ic09", "512x512"), ("ic10", "512x512@2x")]
func length(_ count: Int) -> Data {
    var value = UInt32(count).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var body = Data()
for (type, name) in records {
    let png = try Data(contentsOf: source.appendingPathComponent("icon_\(name).png"))
    guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw CocoaError(.fileReadCorruptFile) }
    body.append(Data(type.utf8)); body.append(length(png.count + 8)); body.append(png)
}
try (Data("icns".utf8) + length(body.count + 8) + body).write(to: destination, options: .atomic)
